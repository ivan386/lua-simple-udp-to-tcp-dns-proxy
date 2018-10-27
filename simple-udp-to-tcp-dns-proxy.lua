
local socket = require "socket" -- подключаем lua socket


--[[--

Напишем простенькую функцию которая позволит отправить дамп пакета в консоль. Хочется видеть что делает прокси.

--]]--

function serialize(data)
    -- Преобразуем символы не входящие в диапазоны a-z и 0-9 и тире в HEX представление '\xFF'
    return "'"..data:gsub("[^a-z0-9-]", function(chr) return ("\\x%02X"):format(chr:byte()) end).."'"
end


--[[--

UDP в TCP и обратно

Пишем две функции которые будут оперировать двумя каналами передачи данных.

--]]--

-- здесь пакеты из UDP пересылаются в TCP поток
function udp_to_tcp_coroutine_function(udp_in, tcp_out, clients)
    repeat
        coroutine.yield() -- возвращаем управление главному циклу
        packet, err_ip, port = udp_in:receivefrom() -- принимаем UDP пакет
        if packet then
            -- > - big endian
            -- I - unsigned integer
            -- 2 - 2 bytes size
            tcp_out:send(((">I2"):pack(#packet))..packet) -- добавляем размер пакета и отправляем в TCP
            local id = (">I2"):unpack(packet:sub(1,2))    -- читаем ID пакета
            clients[id] = {ip=err_ip, port=port}          -- записываем адрес отправителя
            print(os.date("%c", os.time()) ,err_ip, port, ">", serialize(packet)) -- отображаем пакет в консоль
        end
    until false
end

-- здесь пакеты из TCP потока пересылаются к адресату по UDP
function tcp_to_udp_coroutine_function(tcp_in, udp_out, clients)
    repeat
        coroutine.yield() -- возврашяем управление главному циклу
        -- > - big endian
        -- I - unsigned integer
        -- 2 - 2 bytes size
        local packet = tcp_in:receive((">I2"):unpack(tcp_in:receive(2)), nil) -- принимаем TCP пакет
        local id = (">I2"):unpack(packet:sub(1,2))                            -- читаем ID пакета
        local client = clients[id]                                            -- находим получателя
        if client then
            udp_out:sendto(packet, client.ip, client.port) -- отправляем пакет получателю по UDP
            clients[id] = nil                              -- очищаем ячейку
            print(os.date("%c", os.time()) ,client.ip, client.port, "<", serialize(packet)) -- отображаем пакет в консоль
        end
    until false
end


--[[--

Обе функции сразу после запуска выполняют coroutine.yield(). Это позволяет первым вызовом передать параметры функции а дальше делать coroutine.resume(co) без дополнительных параметров.

А теперь main функция которая выполнит подготовку и запустит главный цикл.

--]]--

function main()
    local tcp_dns_socket = socket.tcp() -- подготавливаем TCP сокет
    local udp_dns_socket = socket.udp() -- подготавливаем UDP сокет

    local tcp_connected, err = tcp_dns_socket:connect("127.0.0.1", 53) -- соединяемся с TCP тунелем
    assert(tcp_connected, err) -- проверяем что соединились
    print("tcp dns connected") -- сообщаем что соединились в консоль

    local udp_open, err = udp_dns_socket:setsockname("127.0.0.1", 53) -- открываем UDP порт
    assert(udp_open, err)      -- проверяем что открыли
    print("udp dns port open") -- сообщаем что UDP порт открыт

    -- пользуемся тем что таблицы Lua позволяют использовать как ключ что угодно кроме nil
    -- используем как ключ сокет чтобы при наличии данных на нём вызывать его сопрограмму
    local coroutines = {
        [tcp_dns_socket] = coroutine.create(tcp_to_udp_coroutine_function), -- создаём сопрограмму TCP to UDP
        [udp_dns_socket] = coroutine.create(udp_to_tcp_coroutine_function)  -- создаём сопрограмму UDP to TCP
    }

    local clients = {} -- здесь будут записываться получатели пакетов

    -- передаём каждой сопрограмме сокеты и таблицу получателей
    coroutine.resume(coroutines[tcp_dns_socket], tcp_dns_socket, udp_dns_socket, clients) 
    coroutine.resume(coroutines[udp_dns_socket], udp_dns_socket, tcp_dns_socket, clients)

    -- таблица из которой socket.select будет выбирать сокет готовый к получению данных
    local socket_list = {tcp_dns_socket, udp_dns_socket} 

    repeat -- запускаем главный цикл
        -- socket.select выбирает из socket_list сокеты у которых есть данные на получение в буфере
        -- и возвращает новую таблицу с ними. Цикл for последовательно возвращает значения из новой таблицы  
        for _, in_socket in ipairs(socket.select(socket_list)) do
            -- запускаем ассоциированную с полученным сокетом сопрограмму
            local ok, err = coroutine.resume(coroutines[in_socket])
            if not ok then
                -- если сопрограмма завершилась с ошибкой то
                print(err) -- выводим ошибку
                return     -- завершаем главный цикл
            end
        end
    until false
end


--[[--

Запускаем главную функцию. Если вдруг будет закрыто соединение мы через секунду установим его заново вызвав main.

--]]--

repeat
    coroutine.resume(coroutine.create(main)) -- запускаем main
    socket.sleep(1) -- перед рестартом ждём одну секунду
until false
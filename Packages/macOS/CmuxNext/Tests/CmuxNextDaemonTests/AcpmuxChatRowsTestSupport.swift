import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentList

/// A daemon's v2 bytes for the chat host tests, built the way the recorded stream is: the upgrade
/// reply line, then frames of a 4-byte big-endian length (the kind byte included), a kind byte and
/// JSON. Kinds as in `chat.bytes`: 1 hello, 2 window, 3 ops, 8 error.
enum ChatWire {
    static let recorded: Data = (try? Data(contentsOf: agentChatFixtures.appendingPathComponent("chat.bytes"))) ?? Data()
    /// The upgrade reply, `hello` and the `not_ready` of `rows.1` (the recorded stream's first 300 bytes).
    static var opening: Data { recorded.prefix(300) }
    /// The second connection's upgrade reply (id 2) and `hello` (a reconnect's first bytes, as recorded).
    static var reopening: Data { Data(recorded[2036..<2281]) }

    static func frame(_ kind: UInt8, _ json: String) -> Data {
        let payload = Data(json.utf8)
        var data = Data()
        withUnsafeBytes(of: UInt32(payload.count + 1).bigEndian) { data.append(contentsOf: $0) }
        data.append(kind)
        data.append(payload)
        return data
    }

    static func row(_ id: Int, text: String) -> String {
        "{\"id\":\(id),\"rev\":1,\"kind\":\"assistant\",\"body\":{\"text\":\"\(text)\"}}"
    }

    /// A window of `rows.1` holding rows `ids` (settled), its cursor `cursor`.
    static func window(cursor: Int, ids: some Sequence<Int>, text: (Int) -> String = { "row \($0)" }) -> Data {
        let rows = ids.map { row($0, text: text($0)) }.joined(separator: ",")
        return frame(2, "{\"sid\":\"rows.1\",\"cursor\":\(cursor),\"edition\":1,\"rows\":[\(rows)],\"hasBefore\":\(cursor > 100),\"hasAfter\":false,\"open\":[],\"queue\":{\"entries\":[],\"count\":0}}")
    }

    /// One settled row op of `rows.1` at `seq` (row id `seq`); `replay` marks a resume's ops.
    static func op(_ seq: Int, text: String = "a settled row", replay: String? = nil) -> Data {
        let mark = replay.map { ",\"replay\":\"\($0)\"" } ?? ""
        return frame(3, "{\"sid\":\"rows.1\"\(mark),\"ops\":[{\"op\":\"row\",\"seq\":\(seq),\"row\":\(row(seq, text: text))}]}")
    }

    static func request(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static let open = request(["sid": "rows.1", "chat": "chat-a"])
}

/// A stand-in page receiver: decodes each call the host makes, as the page would, and answers
/// `taken` at once unless told to hold.
final class ChatRowsReceiver: Sendable {
    private struct State {
        var batches: [(batch: Int, changes: [Data])] = []
        var holding = false
        var host: AcpmuxChatRowsHost?
        var failures = 0
        /// When each call reached the receiver (uptime ns), before it decoded anything.
        var arrivals: [UInt64] = []
    }
    private let state = Mutex(State())

    var deliver: @Sendable (String) -> Void {
        { [self] script in
            let arrived = DispatchTime.now().uptimeNanoseconds
            guard let received = try? receivedBatch(script) else {
                state.withLock { $0.failures += 1 }
                return
            }
            let host = state.withLock { state -> AcpmuxChatRowsHost? in
                state.batches.append(received)
                state.arrivals.append(arrived)
                return state.holding ? nil : state.host
            }
            host?.taken(batch: received.batch)
        }
    }

    func attach(_ host: AcpmuxChatRowsHost) { state.withLock { $0.host = host } }
    func hold(_ holding: Bool) { state.withLock { $0.holding = holding } }
    var batches: [(batch: Int, changes: [Data])] { state.withLock { $0.batches } }
    var arrivals: [UInt64] { state.withLock { $0.arrivals } }
    var changes: [Data] { batches.flatMap(\.changes) }
    var failures: Int { state.withLock { $0.failures } }

    /// The row ids of every `chatOp` row and every `chatWindow` row received, in order.
    var rowIds: [Int] {
        changes.flatMap { change -> [Int] in
            guard let object = try? JSONSerialization.jsonObject(with: change) as? [String: Any] else { return [] }
            if let op = object["op"] as? [String: Any], let row = op["row"] as? [String: Any], let id = row["id"] as? Int { return [id] }
            if let window = object["window"] as? [String: Any], let rows = window["rows"] as? [[String: Any]] {
                return rows.compactMap { $0["id"] as? Int }
            }
            return []
        }
    }

    func kinds() -> [String] { changes.compactMap { AcpmuxChatRowsBatch.kind(of: $0) } }
}

/// A host on the driver's feed seam: the test feeds daemon bytes and calls the client itself.
final class FedChatRowsHost: Sendable {
    let receiver = ChatRowsReceiver()
    let host: AcpmuxChatRowsHost
    /// A class, so the connector closures can share it: a `Mutex` itself cannot be copied into them.
    final class Clients: Sendable { let list = Mutex<[AcpmuxClient]>([]) }
    private let clients = Clients()

    /// `hiddenInterval`: a hidden page's pace (long by default, so a test reads a hidden hold).
    init(hiddenInterval: TimeInterval = 600) {
        let clients = self.clients
        host = AcpmuxChatRowsHost(
            socketPath: "/nonexistent", deliver: receiver.deliver,
            makeClient: {
                let client = AcpmuxClient(surfaces: ["chat"])
                clients.list.withLock { $0.append(client) }
                return client
            },
            connector: AcpmuxChatRowsHost.Connector(
                start: { driver, _, onChange, onClose in
                    driver.beginForTesting(onChange: onChange, onClose: onClose)
                    _ = clients.list.withLock { $0.last }?.connected()
                },
                reconnect: { _, _, refused in refused() }),
            hiddenInterval: hiddenInterval)
        receiver.attach(host)
    }

    var clientCount: Int { clients.list.withLock { $0.count } }
    var client: AcpmuxClient? { clients.list.withLock { $0.last } }

    func driver() async -> AcpmuxClientByteConnection? { await host.snapshotForTesting().driver }

    /// Feeds `bytes` in `chunk`-byte reads.
    func feed(_ bytes: Data, chunk: Int) async throws {
        let driver = try #require(await driver())
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + chunk, bytes.endIndex)
            driver.feedForTesting(Data(bytes[offset..<end]))
            offset = end
        }
    }
}

/// Waits up to `seconds` for `condition`, checking every 5 ms.
func eventually(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A daemon socket served by threads of the test process. Connection `n` (from 0) gets
/// `script(n)`'s bytes, written as fast as the client reads them, then is closed when
/// `closeAfter` says so; every byte the client sends is kept.
final class ChatDaemonSocket: @unchecked Sendable { // crash-allow: the listening fd is set once in init and closed once in stop; the rest is behind `state`
    let path: String
    private let listener: Int32
    private struct State {
        var received: [Data] = []
        var written: [Int] = []
        var closed: [Bool] = []
        var clients: [Int32] = []
        var stopped = false
    }
    private let state = Mutex(State())
    private let script: @Sendable (Int) -> (bytes: Data, closeAfter: Bool)

    init(script: @escaping @Sendable (Int) -> (bytes: Data, closeAfter: Bool)) throws {
        self.script = script
        path = "/tmp/rows-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = path
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                let index = state.withLock { state -> Int in
                    state.received.append(Data())
                    state.written.append(0)
                    state.closed.append(false)
                    state.clients.append(client)
                    return state.clients.count - 1
                }
                Thread.detachNewThread { self.read(client, index) }
                Thread.detachNewThread { self.write(client, index) }
            }
        }
    }

    private func read(_ client: Int32, _ index: Int) {
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { break }
            state.withLock { $0.received[index].append(contentsOf: chunk[0..<count]) }
        }
        state.withLock { $0.closed[index] = true }
    }

    private func write(_ client: Int32, _ index: Int) {
        let (bytes, closeAfter) = script(index)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + (16 << 10), bytes.count)
            let sent = bytes[offset..<end].withUnsafeBytes { send(client, $0.baseAddress, end - offset, 0) }
            guard sent > 0 else { return }
            offset += sent
            state.withLock { $0.written[index] = offset }
        }
        if closeAfter { shutdown(client, SHUT_RDWR) }
    }

    var connections: Int { state.withLock { $0.clients.count } }
    func received(_ index: Int) -> Data { state.withLock { index < $0.received.count ? $0.received[index] : Data() } }
    func written(_ index: Int) -> Int { state.withLock { index < $0.written.count ? $0.written[index] : 0 } }
    func clientClosed(_ index: Int) -> Bool { state.withLock { index < $0.closed.count && $0.closed[index] } }

    /// How often `needle` appears in what connection `index` sent.
    func count(_ needle: String, in index: Int) -> Int {
        let data = received(index)
        let pattern = Data(needle.utf8)
        var count = 0
        var start = data.startIndex
        while let found = data.range(of: pattern, in: start..<data.endIndex) {
            count += 1
            start = found.upperBound
        }
        return count
    }

    func stop() {
        let clients = state.withLock { state -> [Int32] in
            state.stopped = true
            return state.clients
        }
        for client in clients { shutdown(client, SHUT_RDWR) }
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }
}

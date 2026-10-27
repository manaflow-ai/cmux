import CmuxNextCompat
import Darwin
import Foundation
@testable import CmuxNextDaemon

/// A Unix socket served by this test process that speaks the attach-streams-v1 half of raw protocol v12
/// (cmux-tui/spec/events.md "Attach streams"): `identify` offers `attach-streams-v1` (or not, with
/// `offersStreams: false`), `attach-surface {stream}` sends its tagged READY, its reply, then
/// `outputBytes[surface]` bytes of tagged `output` in 64 KiB chunks; `cancel-stream` queues
/// `stream-end {canceled}` before its reply, as the daemon's control FIFO does (bounded_outbound.rs). An
/// attach without `stream` is answered untagged, as on a connection of its own. Every request is recorded.
final class StreamWireDaemon: Sendable {
    /// How an attach of a surface in ``Script/failures`` fails.
    enum Failure: Sendable {
        /// After the daemon took the id: `stream-end {attach_failed}`, then the error reply.
        case afterClaim
        /// Before it took the id: only the error reply.
        case beforeClaim
    }

    struct Script: Sendable {
        var offersStreams = true
        var outputBytes: [UInt64: Int] = [:]
        var failures: [UInt64: Failure] = [:]
    }

    /// One request the daemon read.
    struct Request: Sendable, Equatable {
        var connection: Int
        var cmd: String
        var stream: UInt16?
    }

    static let chunkBytes = 64 << 10

    let path: String
    private let listener: Int32
    private let log: Log

    final class Log: Sendable {
        let requests = Mutex<[Request]>([])
        let connections = Atomic<Int>(0)
    }

    init(_ script: Script = Script()) throws {
        path = "/tmp/cnd-strm-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        self.listener = listener
        let log = Log()
        self.log = log
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        let thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                let connection = log.connections.add(1, ordering: .relaxed).newValue
                let serving = Thread { Self.serve(client, connection: connection, script: script, log: log) }
                serving.name = "StreamWireDaemon.serve"
                serving.qualityOfService = .utility
                serving.start()
            }
        }
        thread.name = "StreamWireDaemon.accept"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Requests read so far, in each connection's order.
    var requests: [Request] { log.requests.withLock { $0 } }
    /// Connections accepted so far.
    var connections: Int { log.connections.load(ordering: .relaxed) }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private static func serve(_ client: Int32, connection: Int, script: Script, log: Log) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = request["id"] as? Int, let command = request["cmd"] as? String else { continue }
                let stream = (request["stream"] as? Int).flatMap { UInt16(exactly: $0) }
                log.requests.withLock { $0.append(Request(connection: connection, cmd: command, stream: stream)) }
                guard answer(command, id: id, stream: stream, request: request, to: client, script: script) else { return }
            }
        }
    }

    private static func answer(_ command: String, id: Int, stream: UInt16?, request: [String: Any], to client: Int32,
                               script: Script) -> Bool {
        switch command {
        case IdentifyRequest.command:
            let offered = script.offersStreams ? [TerminalAttachment.streamsCapability] : []
            return reply(id, data: ["app": "cmux-tui", "protocol": 12, "generation": "gen-stream",
                                    "capabilities": offered], to: client)
        case AttachSurfaceRequest.command:
            let surface = request["surface"] as? Int ?? 0
            switch script.failures[UInt64(surface)] {
            case .afterClaim?:
                if let stream, !send(["stream": Int(stream), "event": "stream-end", "reason": "attach_failed"], to: client) {
                    return false
                }
                return fail(id, to: client)
            case .beforeClaim?:
                return fail(id, to: client)
            case nil:
                break
            }
            func item(_ fields: [String: Any]) -> [String: Any] {
                guard let stream else { return fields }
                return fields.merging(["stream": Int(stream)]) { $1 }
            }
            guard send(item(["event": "vt-state", "surface": surface, "cols": 80, "rows": 24, "data": ""]), to: client),
                  reply(id, data: ["lease": "lease-\(id)"], to: client) else { return false }
            var sent = 0
            let total = script.outputBytes[UInt64(surface)] ?? 0
            let byte = UInt8(ascii: "a") + UInt8(surface % 26)
            while sent < total {
                let size = min(chunkBytes, total - sent)
                let data = Data(repeating: byte, count: size).base64EncodedString()
                guard send(item(["event": "output", "surface": surface, "data": data]), to: client) else { return false }
                sent += size
            }
            return true
        case CancelStreamRequest.command:
            let target = request["stream"] as? Int ?? 0
            return send(["stream": target, "event": "stream-end", "reason": "canceled"], to: client)
                && reply(id, data: ["stream": target, "outcome": "applied"], to: client)
        default:
            return reply(id, data: [String: Any](), to: client)
        }
    }

    private static func fail(_ id: Int, to client: Int32) -> Bool {
        send(["id": id, "ok": false, "error": "no such surface", "error_code": "not_found"], to: client)
    }

    private static func reply(_ id: Int, data: [String: Any], to client: Int32) -> Bool {
        send(["id": id, "ok": true, "data": data], to: client)
    }

    private static func send(_ object: [String: Any], to client: Int32) -> Bool {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return false }
        line.append(0x0A)
        return line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(client, base + offset, raw.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}

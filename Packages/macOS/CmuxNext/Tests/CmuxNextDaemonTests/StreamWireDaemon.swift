import CmuxNextCompat
import Darwin
import Foundation
@testable import CmuxNextDaemon

/// A Unix socket served by this test process that speaks the attach-streams-v1 half of raw protocol v12
/// (cmux-tui/spec/events.md "Attach streams"): `identify` offers `attach-streams-v1` (or not, with
/// `offersStreams: false`), `attach-surface {stream}` sends its tagged READY (a `vt-state`, or a `snapshot`
/// READY when ``Script/historyBytes`` names the surface), its reply, then the surface's history chunks and
/// `outputBytes[surface]` bytes of tagged `output` in 64 KiB chunks. `cancel-stream` of an open stream queues
/// `stream-end {canceled}` before its `applied` reply, as the daemon's control FIFO does (bounded_outbound.rs);
/// of any other id it answers `ended` only. An attach without `stream` is answered untagged, as on a connection
/// of its own. Every request is recorded.
final class StreamWireDaemon: Sendable {
    /// How an attach of a surface in ``Script/failures`` fails.
    enum Failure: Sendable {
        /// After the daemon took the id: `stream-end {attach_failed}`, then the error reply.
        case afterClaim
        /// Before it took the id: only the error reply.
        case beforeClaim
        /// Before it took the id, but only once the app gave up on it: the error reply waits for the
        /// stream's `cancel-stream`, which then answers `ended` (no `stream-end` ever comes).
        case beforeClaimAfterTheDeadline
    }

    struct Script: Sendable {
        var offersStreams = true
        var outputBytes: [UInt64: Int] = [:]
        /// Bytes of snapshot history the daemon sends right after the attach reply, behind a `snapshot` READY.
        var historyBytes: [UInt64: Int] = [:]
        var failures: [UInt64: Failure] = [:]
    }

    /// One request the daemon read.
    struct Request: Sendable, Equatable {
        var connection: Int
        var cmd: String
        var stream: UInt16?
    }

    static let chunkBytes = 64 << 10
    /// The generation and cut every `snapshot` line names.
    static let snapshotGeneration = 7
    static let snapshotOffset = 0

    let path: String
    private let listener: Int32
    private let log: Log

    final class Log: Sendable {
        let requests = Mutex<[Request]>([])
        let connections = Atomic<Int>(0)
        /// The connections being served, by descriptor; a served one removes itself before it closes.
        let clients = Mutex<Set<Int32>>([])
    }

    /// What one served connection holds between requests.
    private struct Served {
        var open: Set<UInt16> = []
        /// Attach request ids whose refusal waits for their stream's `cancel-stream`.
        var heldRefusals: [UInt16: Int] = [:]
        /// The stream each surface was last attached on.
        var streams: [Int: UInt16] = [:]
    }

    /// `test-emit-output {surface, bytes}`: the daemon writes `bytes` of tagged `output` for the surface's stream,
    /// then the reply, in wire order (one served connection is one thread, as one daemon client FIFO).
    static let emitOutputCommand = "test-emit-output"

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
                _ = log.clients.withLock { $0.insert(client) }
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

    /// Ends every connection being served, as a daemon that is killed does; the listener stays, so the app
    /// reconnects to it.
    func dropConnections() {
        log.clients.withLock { clients in
            for client in clients { shutdown(client, SHUT_RDWR) }
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private static func serve(_ client: Int32, connection: Int, script: Script, log: Log) {
        defer {
            _ = log.clients.withLock { $0.remove(client) }
            close(client)
        }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        var served = Served()
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
                guard answer(command, id: id, stream: stream, request: request, to: client, script: script,
                             served: &served) else { return }
            }
        }
    }

    private static func answer(_ command: String, id: Int, stream: UInt16?, request: [String: Any], to client: Int32,
                               script: Script, served: inout Served) -> Bool {
        switch command {
        case IdentifyRequest.command:
            let offered = script.offersStreams ? [TerminalAttachment.streamsCapability] : []
            return reply(id, data: ["app": "cmux-tui", "protocol": 12, "generation": "gen-stream",
                                    "capabilities": offered], to: client)
        case AttachSurfaceRequest.command:
            return attach(id: id, stream: stream, surface: request["surface"] as? Int ?? 0, to: client, script: script,
                          served: &served)
        case emitOutputCommand:
            let surface = request["surface"] as? Int ?? 0
            let total = request["bytes"] as? Int ?? 0
            let byte = UInt8(ascii: "a") + UInt8(surface % 26)
            var sent = 0
            while sent < total {
                let size = min(chunkBytes, total - sent)
                var line: [String: Any] = ["event": "output", "surface": surface,
                                           "data": Data(repeating: byte, count: size).base64EncodedString()]
                if let stream = served.streams[surface] { line["stream"] = Int(stream) }
                guard send(line, to: client) else { return false }
                sent += size
            }
            return reply(id, data: [String: Any](), to: client)
        case CancelStreamRequest.command:
            let target = request["stream"] as? Int ?? 0
            let key = UInt16(exactly: target) ?? 0
            if let refused = served.heldRefusals.removeValue(forKey: key), !fail(refused, to: client) { return false }
            guard served.open.remove(key) != nil else {
                return reply(id, data: ["stream": target, "outcome": "ended"], to: client)
            }
            return send(["stream": target, "event": "stream-end", "reason": "canceled"], to: client)
                && reply(id, data: ["stream": target, "outcome": "applied"], to: client)
        default:
            return reply(id, data: [String: Any](), to: client)
        }
    }

    private static func attach(id: Int, stream: UInt16?, surface: Int, to client: Int32, script: Script,
                               served: inout Served) -> Bool {
        switch script.failures[UInt64(surface)] {
        case .afterClaim?:
            if let stream, !send(["stream": Int(stream), "event": "stream-end", "reason": "attach_failed"], to: client) {
                return false
            }
            return fail(id, to: client)
        case .beforeClaim?:
            return fail(id, to: client)
        case .beforeClaimAfterTheDeadline?:
            guard let stream else { return fail(id, to: client) }
            served.heldRefusals[stream] = id
            return true
        case nil:
            break
        }
        func item(_ fields: [String: Any]) -> [String: Any] {
            guard let stream else { return fields }
            return fields.merging(["stream": Int(stream)]) { $1 }
        }
        if let stream {
            served.open.insert(stream)
            served.streams[surface] = stream
        }
        let history = script.historyBytes[UInt64(surface)]
        let ready: [String: Any] = history == nil
            ? ["event": "vt-state", "surface": surface, "cols": 80, "rows": 24, "data": ""]
            : ["event": "snapshot", "surface": surface, "phase": "ready", "generation": snapshotGeneration,
               "offset": snapshotOffset, "version": 1, "cols": 80, "rows": 24, "data": ""]
        guard send(item(ready), to: client), reply(id, data: ["lease": "lease-\(id)"], to: client) else { return false }
        let byte = UInt8(ascii: "a") + UInt8(surface % 26)
        var sent = 0
        while sent < history ?? 0 {
            let size = min(chunkBytes, (history ?? 0) - sent)
            let data = Data(repeating: byte, count: size).base64EncodedString()
            guard send(item(["event": "snapshot", "surface": surface, "phase": "history", "generation": snapshotGeneration,
                             "offset": snapshotOffset, "version": 1, "data": data]), to: client) else { return false }
            sent += size
        }
        sent = 0
        let total = script.outputBytes[UInt64(surface)] ?? 0
        while sent < total {
            let size = min(chunkBytes, total - sent)
            let data = Data(repeating: byte, count: size).base64EncodedString()
            guard send(item(["event": "output", "surface": surface, "data": data]), to: client) else { return false }
            sent += size
        }
        return true
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

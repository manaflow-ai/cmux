import CmuxNextCompat
import CmuxNextIPC
@testable import CmuxNextDaemon
import Darwin
import Foundation

/// A local daemon that speaks lines and, once granted, REQUEST frames, by the grant rule of cmux-tui
/// capabilities.rs: frames at its own revision, after the client echoes them. Like frame_dispatch.rs, it closes
/// the connection on a frame its table does not route and answers `method_not_framed` to a method it serves
/// only as a line.
final class WireDaemon: Sendable {
    struct Script: Sendable {
        /// The framed IPC capabilities `identify` offers.
        var offers: [String]
        /// Its API revision; nil is a daemon from before revisions, which refuses `revisions` and `api_revision`.
        var revision: UInt32?
        /// Its method table, and the `sdk_schema_digest` it names (nil names none).
        var table: MethodTable
        var digest: String?
        /// The method ids it answers on frames (`framed_methods`).
        var served: [UInt16]
    }

    /// One request as the daemon read it.
    struct Seen: Sendable {
        var connection: Int
        var cmd: String
        var framed: Bool
        var methodID: UInt16?
        var priority: UInt8?
        var revisions = false
        var apiRevision: UInt32?
        var capabilities: [String] = []
    }

    let path = "/tmp/cnd-hs-\(UUID().uuidString.prefix(8).lowercased()).sock"
    let seen = Mutex<[Seen]>([])
    /// Frames answered `method_not_framed` or closed as bad messages.
    let refusedFrames = Mutex(0)
    private let listener: Int32
    private let script: Script

    init(_ script: Script) throws {
        self.script = script
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        self.listener = listener
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
        let thread = Thread { [self] in
            var index = 0
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                let connection = index
                index += 1
                let serving = Thread { [self] in serve(client, connection: connection) }
                serving.start()
            }
        }
        thread.start()
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private enum Message {
        case line([UInt8])
        case frame(header: [UInt8], body: [UInt8])
    }

    /// One connection's grant state.
    private struct Session {
        var declared: UInt32?
        var framesGranted = false
    }

    private func serve(_ client: Int32, connection: Int) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var session = Session()
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += chunk[0..<count]
            while let message = Self.cut(&buffer) {
                guard handle(message, session: &session, connection: connection, client: client) else { return }
            }
        }
    }

    private static func cut(_ buffer: inout [UInt8]) -> Message? {
        guard let first = buffer.first else { return nil }
        if first == 0xFF {
            guard buffer.count >= 16 else { return nil }
            let length = Int(UInt32(buffer[4]) | UInt32(buffer[5]) << 8 | UInt32(buffer[6]) << 16 | UInt32(buffer[7]) << 24)
            guard buffer.count >= 16 + length else { return nil }
            let message = Message.frame(header: Array(buffer[0..<16]), body: Array(buffer[16..<16 + length]))
            buffer.removeFirst(16 + length)
            return message
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Array(buffer[0..<newline])
        buffer.removeFirst(newline + 1)
        return .line(line)
    }

    /// Answers one message; false closes the connection (a bad message).
    private func handle(_ message: Message, session: inout Session, connection: Int, client: Int32) -> Bool {
        switch message {
        case .line(let bytes):
            guard let request = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let cmd = request["cmd"] as? String else { return false }
            var seen = Seen(connection: connection, cmd: cmd, framed: false)
            seen.revisions = request["revisions"] as? Bool == true
            seen.apiRevision = (request["api_revision"] as? NSNumber)?.uint32Value
            seen.capabilities = request["capabilities"] as? [String] ?? []
            self.seen.withLock { $0.append(seen) }
            let reply: [String: Any]
            if let data = answer(cmd, request: request, session: &session) {
                reply = ["id": request["id"] ?? NSNull(), "ok": true, "data": data]
            } else {
                reply = ["id": request["id"] ?? NSNull(), "ok": false, "error": "unknown field", "error_code": "bad_request"]
            }
            return Self.write(Self.json(reply), to: client)
        case .frame(let header, let body):
            let methodID = UInt16(header[12]) | UInt16(header[13]) << 8
            guard session.framesGranted, header[1] == 16, header[2] == 0, header[3] == 0, header[15] == 0,
                  let method = script.table.v12(MethodID(rawValue: methodID)),
                  method.priority.rawValue == header[14],
                  let request = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
                  request["cmd"] as? String == method.name else {
                refusedFrames.withLock { $0 += 1 }
                return false
            }
            // Refused before it runs, so it is not seen (frame_dispatch.rs `send_not_framed`).
            let refused = !script.served.contains(methodID)
            if refused {
                refusedFrames.withLock { $0 += 1 }
            } else {
                self.seen.withLock {
                    $0.append(Seen(connection: connection, cmd: method.name, framed: true, methodID: methodID, priority: header[14]))
                }
            }
            let reply: [String: Any] = refused
                ? ["ok": false, "error": "send it as a line", "error_code": "method_not_framed"]
                : ["id": request["id"] ?? NSNull(), "ok": true, "data": answer(method.name, request: request, session: &session) ?? [String: Any]()]
            var frame = header
            frame[1] = refused ? 18 : 17
            let payload = Self.json(reply)
            let length = UInt32(payload.count)
            for byte in 0..<4 { frame[4 + byte] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(byte))) }
            return Self.write(Data(frame) + payload, to: client, newline: false)
        }
    }

    /// The `data` of a command, or nil for a refusal.
    private func answer(_ cmd: String, request: [String: Any], session: inout Session) -> Any? {
        switch cmd {
        case "identify":
            if request["revisions"] != nil, script.revision == nil { return nil }
            var offers = script.offers
            if let declared = session.declared, declared != script.revision { offers.removeAll { $0 == WireNegotiation.framesCapability } }
            var identity: [String: Any] = ["app": "cmux-tui", "protocol": 12, "generation": "wire-test", "capabilities": offers]
            if request["revisions"] as? Bool == true, let revision = script.revision {
                identity["api_revision"] = revision
                if offers.contains(WireNegotiation.framesCapability), let digest = script.digest {
                    identity["sdk_schema_digest"] = digest
                    identity["framed_methods"] = script.served.map { NSNumber(value: $0) }
                }
            }
            return identity
        case "set-client-info":
            let declared = (request["api_revision"] as? NSNumber)?.uint32Value
            if declared != nil, script.revision == nil { return nil }
            if let declared { session.declared = declared }
            let capabilities = request["capabilities"] as? [String] ?? []
            session.framesGranted = capabilities.contains(WireNegotiation.framesCapability)
                && script.offers.contains(WireNegotiation.framesCapability)
                && session.declared != nil && session.declared == script.revision
            return [String: Any]()
        case "client-hello":
            return ["connection_id": "wire-test"]
        case "subscribe":
            return [String: Any]()
        default:
            return ["cmd": cmd, "text": request["text"] ?? NSNull()] as [String: Any]
        }
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func write(_ message: Data, to client: Int32, newline: Bool = true) -> Bool {
        var bytes = message
        if newline { bytes.append(0x0A) }
        return bytes.withUnsafeBytes { raw in
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

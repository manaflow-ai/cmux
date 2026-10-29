import CryptoKit
import Foundation

/// A byte stream a WebSocket rides: a tunnel to the server's websockify. The
/// app supplies it, so this package never opens a socket of its own here.
public protocol RFBByteStream: Sendable {
    /// The next bytes, at least one. Throws `RFBError.connectionClosed` at the end of the stream.
    func read() async throws -> [UInt8]
    /// Writes `bytes` whole, in call order.
    func write(_ bytes: [UInt8]) async throws
    func close()
}

/// RFB inside a WebSocket (RFC 6455) as websockify serves it next to noVNC: binary
/// messages carry the RFB bytes. Lets the native client reach a desktop whose VNC
/// server only listens on its own loopback, through the same websockify port noVNC
/// uses, over a stream the app opens (its Cloud tunnel). Client frames are masked;
/// pings are answered; a close frame ends the stream.
public final class WebSocketRFBTransport: RFBTransport {
    private let core: Core
    private let stream = StreamSlot()

    /// - Parameters:
    ///   - host: The `Host` header (websockify ignores it; `localhost:6901` matches noVNC).
    ///   - path: The request path; websockify upgrades any path.
    ///   - open: Opens the byte stream to the websockify port.
    public init(host: String, path: String = "/websockify", open: @escaping @Sendable () async throws -> any RFBByteStream) {
        core = Core(host: host, path: path, open: open)
    }

    public func open() async throws {
        try await core.open(into: stream)
    }

    public func receive() async throws -> [UInt8] {
        try await core.receive()
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        try await core.send(Self.frame(opcode: Opcode.binary, payload: bytes))
    }

    public func close() {
        stream.close()
    }

    // MARK: Framing

    enum Opcode {
        static let continuation: UInt8 = 0x0
        static let text: UInt8 = 0x1
        static let binary: UInt8 = 0x2
        static let close: UInt8 = 0x8
        static let ping: UInt8 = 0x9
        static let pong: UInt8 = 0xA
    }

    /// Largest server message accepted; a full 4K framebuffer update fits many times over.
    static let maximumPayload = 64 << 20

    /// One final client frame, masked with a fresh key (RFC 6455 5.3).
    static func frame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x80 | opcode]
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ..<65_536:
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        default:
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 0xFF) })
        }
        var generator = SystemRandomNumberGenerator()
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        frame.append(contentsOf: mask)
        frame.reserveCapacity(frame.count + payload.count)
        for (index, byte) in payload.enumerated() { frame.append(byte ^ mask[index & 3]) }
        return frame
    }

    /// The `Sec-WebSocket-Accept` a server must answer for `key` (RFC 6455 4.2.2).
    static func accept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// The stream once opened; a close before or after the open closes it.
    // crash-allow: `stream` and `closed` are read and written only while `lock` is held.
    final class StreamSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var stream: (any RFBByteStream)?
        private var closed = false

        /// Holds `opened`; false (and `opened` closed) after a close.
        func hold(_ opened: any RFBByteStream) -> Bool {
            lock.lock()
            guard !closed else {
                lock.unlock()
                opened.close()
                return false
            }
            stream = opened
            lock.unlock()
            return true
        }

        func close() {
            lock.lock()
            closed = true
            let stream = stream
            self.stream = nil
            lock.unlock()
            stream?.close()
        }
    }

    /// The handshake and the frames: one reader (the RFB session) and any number of writers.
    actor Core {
        private let host: String
        private let path: String
        private let opener: @Sendable () async throws -> any RFBByteStream
        private var stream: (any RFBByteStream)?
        private var buffer: [UInt8] = []
        private var ended = false

        init(host: String, path: String, open: @escaping @Sendable () async throws -> any RFBByteStream) {
            self.host = host
            self.path = path
            opener = open
        }

        func open(into slot: StreamSlot) async throws {
            let opened = try await opener()
            guard slot.hold(opened) else { throw RFBError.connectionClosed }
            stream = opened
            var generator = SystemRandomNumberGenerator()
            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
            try await opened.write(Array(request.utf8))
            let head = try await readHead(from: opened)
            try Self.checkHandshake(head, key: key)
        }

        /// The response head up to its blank line; the bytes after it are frames.
        private func readHead(from stream: any RFBByteStream) async throws -> String {
            let end: [UInt8] = [13, 10, 13, 10]
            while true {
                if let range = buffer.firstRange(of: end) {
                    let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(..<range.upperBound)
                    return head
                }
                guard buffer.count < 16 * 1024 else { throw RFBError.protocolViolation("websocket response head too long") }
                buffer.append(contentsOf: try await stream.read())
            }
        }

        static func checkHandshake(_ head: String, key: String) throws {
            let lines = head.components(separatedBy: "\r\n")
            let status = lines.first?.split(separator: " ", maxSplits: 2) ?? []
            guard status.count >= 2, status[0].hasPrefix("HTTP/1."), status[1] == "101" else {
                throw RFBError.transport("websocket upgrade refused: \(lines.first ?? "")")
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["upgrade"]?.lowercased() == "websocket",
                  headers["sec-websocket-accept"] == WebSocketRFBTransport.accept(for: key) else {
                throw RFBError.protocolViolation("websocket upgrade answer does not match the request")
            }
        }

        func receive() async throws -> [UInt8] {
            guard let stream else { throw RFBError.connectionClosed }
            while true {
                if ended { throw RFBError.connectionClosed }
                if let (opcode, payload) = try takeFrame() {
                    switch opcode {
                    case Opcode.binary, Opcode.continuation:
                        if !payload.isEmpty { return payload }
                    case Opcode.ping:
                        try await stream.write(WebSocketRFBTransport.frame(opcode: Opcode.pong, payload: payload))
                    case Opcode.pong:
                        break
                    case Opcode.close:
                        ended = true
                        try? await stream.write(WebSocketRFBTransport.frame(opcode: Opcode.close, payload: Array(payload.prefix(2))))
                        throw RFBError.connectionClosed
                    default:
                        // Text would be websockify's base64 mode, which the binary request never selects.
                        throw RFBError.protocolViolation("websocket opcode \(opcode)")
                    }
                    continue
                }
                buffer.append(contentsOf: try await stream.read())
            }
        }

        func send(_ frame: [UInt8]) async throws {
            guard let stream, !ended else { throw RFBError.connectionClosed }
            try await stream.write(frame)
        }

        /// One whole frame off the buffer, unmasked; nil while it is incomplete.
        private func takeFrame() throws -> (UInt8, [UInt8])? {
            guard buffer.count >= 2 else { return nil }
            let opcode = buffer[0] & 0x0F
            let masked = buffer[1] & 0x80 != 0
            var length = Int(buffer[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return nil }
                length = Int(buffer[2]) << 8 | Int(buffer[3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return nil }
                var value: UInt64 = 0
                for byte in buffer[2..<10] { value = value << 8 | UInt64(byte) }
                guard value <= UInt64(WebSocketRFBTransport.maximumPayload) else {
                    throw RFBError.protocolViolation("websocket message of \(value) bytes")
                }
                length = Int(value)
                offset = 10
            }
            guard length <= WebSocketRFBTransport.maximumPayload else {
                throw RFBError.protocolViolation("websocket message of \(length) bytes")
            }
            let mask: [UInt8]
            if masked {
                guard buffer.count >= offset + 4 else { return nil }
                mask = Array(buffer[offset..<offset + 4])
                offset += 4
            } else {
                mask = []
            }
            guard buffer.count >= offset + length else { return nil }
            var payload = Array(buffer[offset..<offset + length])
            if masked { for index in payload.indices { payload[index] ^= mask[index & 3] } }
            buffer.removeSubrange(..<(offset + length))
            return (opcode, payload)
        }
    }
}

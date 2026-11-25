import CmuxVNCDemoServer
import Foundation
import Testing
@testable import CmuxVNC

/// RFB inside a WebSocket, as websockify serves it next to noVNC: the client against the
/// loopback demo server through an in-process websockify stand-in that checks every client
/// frame is masked, splits server frames across reads and pings once.
struct WebSocketTransportTests {
    /// websockify's server side over a TCP connection to the demo server.
    actor Websockify: RFBByteStream {
        enum Answer { case accept, wrongAccept, refuse }

        private let upstream: NetworkRFBTransport
        private let answer: Answer
        private var request: [UInt8] = []
        private var inbound: [UInt8] = []
        private var upgraded = false
        private var queued: [[UInt8]] = []
        private(set) var unmaskedFrames = 0
        private(set) var pongs = 0
        private(set) var path = ""

        init(port: UInt16, answer: Answer = .accept) {
            upstream = NetworkRFBTransport(host: "127.0.0.1", port: port)
            self.answer = answer
        }

        func read() async throws -> [UInt8] {
            if !queued.isEmpty { return queued.removeFirst() }
            guard upgraded else { throw RFBError.connectionClosed }
            let frame = Self.serverFrame(opcode: 0x2, payload: try await upstream.receive())
            // Split every frame across two reads, so the client reassembles it.
            let half = max(1, frame.count / 2)
            queued.append(Array(frame[half...]))
            return Array(frame[..<half])
        }

        func write(_ bytes: [UInt8]) async throws {
            guard upgraded else { return try await handshake(bytes) }
            inbound.append(contentsOf: bytes)
            while let (opcode, payload, masked) = takeClientFrame() {
                if !masked { unmaskedFrames += 1 }
                switch opcode {
                case 0x2: try await upstream.send(payload)
                case 0xA: pongs += 1
                default: break
                }
            }
        }

        nonisolated func close() {
            upstream.close()
        }

        private func handshake(_ bytes: [UInt8]) async throws {
            request.append(contentsOf: bytes)
            let text = String(decoding: request, as: UTF8.self)
            guard text.hasSuffix("\r\n\r\n") else { return }
            let lines = text.components(separatedBy: "\r\n")
            path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let key = lines.first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
            switch answer {
            case .refuse:
                queued.append(Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
                return
            case .wrongAccept, .accept:
                let accept = answer == .accept ? WebSocketRFBTransport.accept(for: key) : "bm90IHRoZSBhbnN3ZXI="
                // The 101 head and the first frame (a ping) arrive in one read.
                let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
                queued.append(Array(head.utf8) + Self.serverFrame(opcode: 0x9, payload: Array("hi".utf8)))
            }
            try await upstream.open()
            upgraded = true
        }

        private func takeClientFrame() -> (UInt8, [UInt8], Bool)? {
            guard inbound.count >= 2 else { return nil }
            let opcode = inbound[0] & 0x0F, masked = inbound[1] & 0x80 != 0
            var length = Int(inbound[1] & 0x7F), offset = 2
            if length == 126 {
                guard inbound.count >= 4 else { return nil }
                length = Int(inbound[2]) << 8 | Int(inbound[3])
                offset = 4
            } else if length == 127 {
                guard inbound.count >= 10 else { return nil }
                length = inbound[2..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            let maskLength = masked ? 4 : 0
            guard inbound.count >= offset + maskLength + length else { return nil }
            let mask = Array(inbound[offset..<offset + maskLength])
            var payload = Array(inbound[(offset + maskLength)..<(offset + maskLength + length)])
            if masked { for index in payload.indices { payload[index] ^= mask[index & 3] } }
            inbound.removeSubrange(..<(offset + maskLength + length))
            return (opcode, payload, masked)
        }

        static func serverFrame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
            var frame: [UInt8] = [0x80 | opcode]
            if payload.count < 126 {
                frame.append(UInt8(payload.count))
            } else if payload.count < 65_536 {
                frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
            } else {
                frame.append(127)
                frame += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
            }
            return frame + payload
        }
    }

    @Test(.timeLimit(.minutes(1))) func theClientStreamsThroughWebsockify() async throws {
        let server = VNCDemoServer(configuration: .init(width: 320, height: 200, framesPerSecond: 30))
        let port = try await server.start()
        defer { server.stop() }
        let websockify = Websockify(port: port)
        let transport = WebSocketRFBTransport(host: "localhost:6901") { websockify }
        let client = VNCClient(endpoint: VNCEndpoint(host: "vm-test", port: 5901), transport: transport)
        await client.connect()
        var events = client.events.makeAsyncIterator()
        guard case let .connected(info)? = await events.next() else {
            Issue.record("did not connect through the WebSocket")
            return
        }
        #expect(info.width == 320 && info.height == 200)
        var frames = 0
        for await frame in client.frames {
            #expect(frame.width == 320 && frame.height == 200)
            frames += 1
            if frames == 3 { break }
        }
        await client.type("ok")
        #expect(frames == 3)
        #expect(await websockify.path == "/websockify")
        #expect(await websockify.unmaskedFrames == 0, "every client frame is masked (RFC 6455 5.3)")
        #expect(await websockify.pongs == 1, "the server's ping is answered")
        await client.disconnect()
    }

    @Test(arguments: [Websockify.Answer.wrongAccept, .refuse])
    func aBadUpgradeAnswerEndsTheSession(_ answer: Websockify.Answer) async throws {
        let server = VNCDemoServer(configuration: .init(width: 64, height: 64, framesPerSecond: 0))
        let port = try await server.start()
        defer { server.stop() }
        let websockify = Websockify(port: port, answer: answer)
        let client = VNCClient(endpoint: VNCEndpoint(host: "vm-test", port: 5901),
                               transport: WebSocketRFBTransport(host: "localhost:6901") { websockify })
        await client.connect()
        var last: VNCEvent?
        for await event in client.events { last = event }
        guard case .disconnected(_?)? = last else {
            Issue.record("expected a failure, got \(String(describing: last))")
            return
        }
    }

    @Test func framesAreMaskedAndSizedForEveryLength() {
        for count in [0, 125, 126, 65_535, 65_536] {
            let payload = [UInt8](repeating: 0x5A, count: count)
            let frame = WebSocketRFBTransport.frame(opcode: 0x2, payload: payload)
            #expect(frame[0] == 0x82)
            #expect(frame[1] & 0x80 != 0, "masked")
            let header = count < 126 ? 2 : (count < 65_536 ? 4 : 10)
            #expect(frame.count == header + 4 + count)
            let mask = Array(frame[header..<header + 4])
            let unmasked = frame[(header + 4)...].enumerated().map { $0.element ^ mask[$0.offset & 3] }
            #expect(unmasked == payload)
        }
        // RFC 6455 section 1.3's example key and answer.
        #expect(WebSocketRFBTransport.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

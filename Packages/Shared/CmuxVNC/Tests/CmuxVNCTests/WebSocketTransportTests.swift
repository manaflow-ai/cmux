import Foundation
import Testing
@testable import CmuxVNC

/// Focused WebSocket framing and upgrade tests that run without a listening socket.
struct WebSocketTransportTests {
    actor ScriptedStream: RFBByteStream {
        enum Response: Sendable { case wrongAccept, refuse }

        private let response: Response
        private var answered = false
        private var queued: [[UInt8]] = []

        init(response: Response) {
            self.response = response
        }

        func read() async throws -> [UInt8] {
            guard !queued.isEmpty else { throw RFBError.connectionClosed }
            return queued.removeFirst()
        }

        func write(_ bytes: [UInt8]) async throws {
            guard !answered else { return }
            let request = String(decoding: bytes, as: UTF8.self)
            guard request.hasSuffix("\r\n\r\n") else { return }
            answered = true
            switch response {
            case .refuse:
                queued.append(Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
            case .wrongAccept:
                queued.append(Array(("HTTP/1.1 101 Switching Protocols\r\n"
                    + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: bm90IHRoZSBhbnN3ZXI=\r\n\r\n").utf8))
            }
        }

        nonisolated func close() {}
    }

    private func failure(for response: ScriptedStream.Response) async -> RFBError? {
        let stream = ScriptedStream(response: response)
        let client = VNCClient(
            endpoint: VNCEndpoint(host: "vm-test", port: 5901),
            transport: WebSocketRFBTransport(host: "localhost:6901") { stream })
        await client.connect()
        var last: VNCEvent?
        for await event in client.events { last = event }
        guard case let .disconnected(error)? = last else {
            Issue.record("expected a failed WebSocket upgrade, got \(String(describing: last))")
            return nil
        }
        return error
    }

    @Test func aWrongUpgradeAnswerEndsTheSessionWithAProtocolViolation() async {
        let error = await failure(for: .wrongAccept)
        #expect(error == .protocolViolation("websocket upgrade answer does not match the request"))
    }

    @Test func aRefusedUpgradeAnswerEndsTheSessionWithATransportError() async {
        let error = await failure(for: .refuse)
        #expect(error == .transport("websocket upgrade refused: HTTP/1.1 400 Bad Request"))
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
        #expect(WebSocketRFBTransport.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

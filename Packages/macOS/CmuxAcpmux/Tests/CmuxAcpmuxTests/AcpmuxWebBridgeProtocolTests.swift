import CmuxAcpmux
import Foundation
import Testing

@Suite struct AcpmuxWebBridgeProtocolTests {
    @Test func handshakeRoundTrips() throws {
        let handshake = AcpmuxWebHostHandshake(
            endpoint: "ws://127.0.0.1:47811",
            token: "launch-token",
            sessionId: "session-1"
        )
        let encoded = try JSONEncoder().encode(handshake)
        let decoded = try JSONDecoder().decode(AcpmuxWebHostHandshake.self, from: encoded)
        #expect(decoded == handshake)
        #expect(decoded.protocolVersion == 1)
        #expect(decoded.transport == "acpmux-websocket")
    }
}

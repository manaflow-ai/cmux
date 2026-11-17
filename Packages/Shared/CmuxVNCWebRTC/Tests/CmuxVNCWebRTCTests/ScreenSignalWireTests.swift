@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// The app's ticket signaling and the helper's capture talk over a local socket: every signal
/// and the session's ICE servers survive a JSON round trip unchanged.
@Suite struct ScreenSignalWireTests {
    @Test(arguments: [
        ScreenSignal.hello(peerPresent: true), .hello(peerPresent: false), .peerJoined, .peerLeft,
        .offer("v=0\r\na=fingerprint:sha-256 AA"), .answer("v=0"),
        .candidate(ScreenICECandidate(candidate: "candidate:1 1 udp 1 10.0.0.1 5000 typ host", sdpMid: "0", sdpMLineIndex: 0)),
        .candidate(ScreenICECandidate(candidate: "c", sdpMid: nil, sdpMLineIndex: nil)),
        .bye, .path(relay: true), .path(relay: false),
    ])
    func everySignalRoundTripsThroughJSON(_ signal: ScreenSignal) throws {
        let data = try JSONSerialization.data(withJSONObject: ScreenSignalWire.fields(signal))
        let fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(ScreenSignalWire.signal(fields) == signal)
    }

    @Test func anObjectThatIsNoSignalReadsAsNil() {
        #expect(ScreenSignalWire.signal(["type": "nonsense"]) == nil)
        #expect(ScreenSignalWire.signal(["type": "offer"]) == nil)
    }

    @Test func iceServersRoundTrip() throws {
        let servers = [ICEServerConfig(urls: ["stun:stun.example:3478"]),
                       ICEServerConfig(urls: ["turn:turn.example:3478?transport=udp"], username: "u", credential: "p")]
        let data = try JSONSerialization.data(withJSONObject: ScreenSignalWire.fields(servers))
        #expect(ScreenSignalWire.servers(try JSONSerialization.jsonObject(with: data)) == servers)
    }
}

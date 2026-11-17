@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// The attached capture channel's lines (cmux app <-> cmux Remote's Screen Sharing worker): every
/// signal and event survives a JSON line round trip unchanged.
struct AttachedScreenHostTests {
    @Test(arguments: [
        ScreenSignal.hello(peerPresent: true), .peerJoined, .peerLeft, .offer("v=0 offer"), .answer("v=0 answer"),
        .candidate(ScreenICECandidate(candidate: "candidate:1 1 udp 1 10.0.0.1 9 typ host", sdpMid: "0", sdpMLineIndex: 0)),
        .candidate(ScreenICECandidate(candidate: "candidate:2", sdpMid: nil, sdpMLineIndex: nil)),
        .bye, .path(relay: true),
    ])
    func aSignalSurvivesTheChannel(signal: ScreenSignal) throws {
        let data = try JSONSerialization.data(withJSONObject: AttachedScreenHost.line(signal))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(AttachedScreenHost.signal(object) == signal)
    }

    @Test func anEventSurvivesTheChannel() throws {
        for event in [AttachedScreenHost.Event.viewerConnected, .viewerEnded("left"), .sourceFailed("no display")] {
            let data = try JSONSerialization.data(withJSONObject: event.fields)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(AttachedScreenHost.Event(fields: object) == event)
            #expect(AttachedScreenHost.signal(object) == nil)
        }
    }

    @Test func iceServersSurviveTheChannel() throws {
        let servers = [ICEServerConfig(urls: ["stun:stun.example.test:3478"]),
                       ICEServerConfig(urls: ["turn:turn.example.test:3478"], username: "u", credential: "c")]
        let data = try JSONSerialization.data(withJSONObject: AttachedScreenHost.fields(servers))
        #expect(AttachedScreenHost.servers(try JSONSerialization.jsonObject(with: data)) == servers)
    }

    @Test func anUnknownSignalIsNotGuessed() {
        #expect(AttachedScreenHost.signal(["signal": ["type": "later"]]) == nil)
        #expect(AttachedScreenHost.signal(["signal": ["type": "offer"]]) == nil)
    }
}

import Foundation
import Testing
@testable import CmuxNextRemoteView

/// The control JSON both sides speak: the host's `Control` enum in
/// cmux-tui/crates/cmux-rd-host/src/wire.rs (serde, tag `t`, snake case).
struct RemoteRdControlTests {
    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func helloUsesTheHostFieldNamesAndOmitsAbsentOptions() throws {
        let hello = RemoteRdHello(user: "u", install: "i", token: String(repeating: "a", count: 64), caps: ["stream.open"])
        let json = try Self.object(try RemoteRdControl.hello(hello).json())
        #expect(json["t"] as? String == "hello")
        #expect(json["class"] as? String == "user")
        #expect(json["interactive"] as? Bool == true)
        #expect(json["max_datagram"] as? Int == 1152)
        #expect(json["service"] as? String == "desktop")
        #expect(json["caps"] as? [String] == ["stream.open"])
        #expect(json["udp_port"] == nil)
        #expect(Set(json.keys) == ["t", "user", "install", "class", "interactive", "max_datagram", "token", "service", "caps"])
    }

    @Test func stopMatchesTheGoldenFramingVector() throws {
        // The host and cmux-rd-proto pin `{"t":"stop"}` in their framing vector.
        #expect(String(decoding: try RemoteRdControl.stop.json(), as: UTF8.self) == #"{"t":"stop"}"#)
    }

    @Test func hostMessagesParse() throws {
        let welcome = #"{"t":"welcome","encoder":"x264","width":1920,"height":1080,"max_datagram":1152,"carrier":"stream","service":"desktop","caps":[]}"#
        #expect(try RemoteRdControl.parse(Data(welcome.utf8)) == .welcome(RemoteRdWelcome(
            encoder: "x264", width: 1920, height: 1080, maxDatagram: 1152, carrier: "stream", service: "desktop", caps: []
        )))
        // A host older than C1 sends no service and no caps.
        let old = #"{"t":"welcome","encoder":"openh264","width":2,"height":2,"max_datagram":1332,"carrier":"udp"}"#
        guard case let .welcome(w) = try RemoteRdControl.parse(Data(old.utf8)) else { Issue.record("not a welcome"); return }
        #expect(w.service == nil)
        #expect(try RemoteRdControl.parse(Data(#"{"t":"started","session":7}"#.utf8)) == .started(session: 7))
        #expect(try RemoteRdControl.parse(Data(#"{"t":"refused","reason":"service"}"#.utf8)) == .refused(reason: "service"))
        #expect(try RemoteRdControl.parse(Data(#"{"t":"ended","reason":"stop"}"#.utf8)) == .ended(reason: "stop"))
        let stats = #"{"t":"stats","kbps":900,"frames":10,"keyframes":1,"cpu_pct":12.5,"encode_ms_p50":4.0,"loss_pct":0.0}"#
        guard case let .stats(s) = try RemoteRdControl.parse(Data(stats.utf8)) else { Issue.record("not stats"); return }
        #expect(s.kbps == 900 && s.cpuPercent == 12.5)
        #expect(try RemoteRdControl.parse(Data(#"{"t":"cursor_shape","hash":1}"#.utf8)) == .unknown("cursor_shape"))
    }

    @Test func startRoundTrips() throws {
        let start = RemoteRdControl.start(key: "display:0", mode: "control")
        #expect(try RemoteRdControl.parse(try start.json()) == start)
    }
}

/// The session setup order (hello, start; welcome, started) and how every
/// end maps to the pane's states.
struct RemoteRdHandshakeTests {
    static let welcome = RemoteRdWelcome(encoder: "x264", width: 8, height: 8, maxDatagram: 1152, carrier: "stream", service: "desktop", caps: [])

    @Test func welcomeThenStartedStreams() {
        var h = RemoteRdHandshake(service: "desktop")
        #expect(h.sessionState == .connecting)
        h.receive(.welcome(Self.welcome))
        #expect(h.sessionState == .connecting)
        h.receive(.stats(RemoteRdHostStats(kbps: 1, frames: 1, keyframes: 1, cpuPercent: 0, encodeMsP50: 0, lossPercent: 0)))
        h.receive(.started(session: 3))
        #expect(h.phase == .streaming(session: 3))
        h.receive(.ended(reason: "host"))
        #expect(h.sessionState == .ended(.hostStoppedSharing))
    }

    @Test func refusalsStopsAndProtocolErrors() {
        var refused = RemoteRdHandshake(service: "desktop")
        refused.receive(.refused(reason: "BadToken"))
        #expect(refused.sessionState == .ended(.consentDenied))

        var stopped = RemoteRdHandshake(service: "desktop")
        stopped.receive(.welcome(Self.welcome))
        stopped.receive(.started(session: 1))
        stopped.viewerStopped()
        stopped.receive(.ended(reason: "stop"))
        #expect(stopped.sessionState == .ended(.stoppedByViewer))

        var outOfOrder = RemoteRdHandshake(service: "desktop")
        outOfOrder.receive(.started(session: 1))
        #expect(outOfOrder.sessionState == .ended(.connectionLost))

        var wrongService = RemoteRdHandshake(service: "rb/1")
        wrongService.receive(.welcome(Self.welcome))
        #expect(wrongService.sessionState == .ended(.connectionLost))

        var lost = RemoteRdHandshake(service: "desktop")
        lost.connectionClosed()
        #expect(lost.sessionState == .ended(.connectionLost))
        // An end is final.
        lost.receive(.welcome(Self.welcome))
        #expect(lost.sessionState == .ended(.connectionLost))
    }
}

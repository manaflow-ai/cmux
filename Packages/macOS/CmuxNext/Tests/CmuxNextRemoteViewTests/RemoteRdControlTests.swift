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

    /// The golden vectors the Rust `cmux_rd_proto::control::Control` reads
    /// (cmux-tui/crates/cmux-rd-proto/tests/vectors/control.json).
    static func vectors() throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cmux-tui/crates/cmux-rd-proto/tests/vectors/control.json")
        let list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var out: [String: [String: Any]] = [:]
        for entry in list {
            let name = try #require(entry["name"] as? String)
            out[name] = try #require(entry["json"] as? [String: Any])
        }
        return out
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test func hostMessagesInTheSharedVectorsParse() throws {
        let v = try Self.vectors()
        for name in ["welcome", "started", "refused", "ended", "stats"] {
            let control = try RemoteRdControl.parse(try Self.data(try #require(v[name])))
            if case .unknown = control { Issue.record("\(name) parsed as unknown") }
        }
    }

    /// rd change B3.2: a service's message (an rb/1 body) passes through
    /// untouched in both directions, matching the shared vector.
    @Test func aServiceMessageRoundTripsItsBodyUntouched() throws {
        let v = try Self.vectors()
        let vector = try #require(v["service"])
        let control = try RemoteRdControl.parse(try Self.data(vector))
        guard case let .service(service, body) = control else {
            Issue.record("service parsed as \(control)")
            return
        }
        #expect(service == "rb/1")
        let bodyObject = try Self.object(try JSONEncoder().encode(body))
        #expect(NSDictionary(dictionary: bodyObject) == NSDictionary(dictionary: try #require(vector["body"] as? [String: Any])))
        let again = try Self.object(try control.json())
        #expect(NSDictionary(dictionary: again) == NSDictionary(dictionary: vector))
    }

    @Test func viewerMessagesEncodeLikeTheSharedVectors() throws {
        let v = try Self.vectors()
        let hello = RemoteRdHello(user: "u", install: "i", token: String(repeating: "ab", count: 32), caps: ["stream.open"])
        var expectedHello = try #require(v["hello"])
        // Swift omits a nil udp_port; serde reads a missing Option as None.
        expectedHello["udp_port"] = nil
        #expect(NSDictionary(dictionary: try Self.object(try RemoteRdControl.hello(hello).json())) == NSDictionary(dictionary: expectedHello))
        let start = try Self.object(try RemoteRdControl.start(key: "display:0", mode: "control").json())
        #expect(NSDictionary(dictionary: start) == NSDictionary(dictionary: try #require(v["start"])))
        let stop = try Self.object(try RemoteRdControl.stop.json())
        #expect(NSDictionary(dictionary: stop) == NSDictionary(dictionary: try #require(v["stop"])))
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

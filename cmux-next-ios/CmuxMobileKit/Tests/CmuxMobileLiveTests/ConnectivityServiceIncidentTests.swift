@testable import CmuxMobileLive
import Foundation
import Testing

/// cmux service sockets (Mac presence, Cloud Chief, the device hub) get the same bar as a Mac link: 30 s
/// unreachable while the app is in front and the phone's internet works, or three drops in five minutes.
@Suite struct ConnectivityServiceIncidentTests {
    typealias Detector = ConnectivityIncidentDetector
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func detector() -> Detector {
        let counter = ConnectivityIncidentDetectorTests.Counter()
        var detector = Detector(makeID: { counter.next() })
        _ = detector.appActive(true, at: t0)
        _ = detector.network("wifi", at: t0)
        return detector
    }

    static let dialing = Detector.LinkState.trying(transport: "websocket", reason: nil, newDial: true)
    static let live = Detector.LinkState.connected(transport: "websocket")

    func check(_ outputs: [Detector.Output]) -> (key: String, id: Int)? {
        for output in outputs { if case .check(let key, let id) = output { return (key, id) } }
        return nil
    }

    func reports(_ outputs: [Detector.Output]) -> [Detector.Incident] {
        outputs.compactMap { if case .report(let incident) = $0 { incident } else { nil } }
    }

    /// Keeps `surface` failing from `start` to `end`, answering each check with `internet`.
    func down(_ d: inout Detector, _ surface: Detector.Surface, from start: TimeInterval, to end: TimeInterval,
              internet: Bool = true, service: Bool = true) -> [Detector.Output] {
        var out = d.service(surface, Self.dialing, at: at(start))
        var now = start
        while now < end {
            now += 5
            let step = d.service(surface, .trying(transport: "websocket", reason: "hello timed out", newDial: true), at: at(now)) + d.tick(at: at(now))
            out += step
            if let (key, id) = check(step) {
                out += d.reachability(macID: key, checkID: id, internet: internet, service: service, at: at(now))
            }
        }
        return out
    }

    @Test func aServiceSocketDownFor30sIsReportedUnderItsSurfaceThenResolves() throws {
        var d = detector()
        #expect(reports(down(&d, .presence, from: 20, to: 45)).isEmpty)
        let open = try #require(reports(down(&d, .presence, from: 45, to: 60)).first)
        #expect(open.kind == .serviceUnreachable)
        #expect(open.surface == .presence)
        #expect(open.macID == "service:presence")
        #expect(open.macName == "Mac presence")
        #expect(open.lastError == "hello timed out")
        #expect((open.attempts ?? 0) > 1)
        let up = reports(d.service(.presence, Self.live, at: at(70)))
        #expect(up.map(\.state) == [.resolved])
        #expect(up.first?.id == open.id)
    }

    @Test func theRestartAtTheFirstDialDoesNotLoseTheStretch() {
        // `down` re-sends trying with newDial (each reconnect attempt): the stretch keeps its start.
        var d = detector()
        let out = down(&d, .chiefCloud, from: 0, to: 40)
        #expect(reports(out).first?.startedAt == at(0))
    }

    @Test func aPhoneWithoutInternetNeverReportsAService() {
        var d = detector()
        #expect(reports(down(&d, .chiefCloud, from: 0, to: 120, internet: false)).isEmpty)
    }

    @Test func theBackgroundAndSignOutAreNeverAServiceOutage() {
        var d = detector()
        _ = d.service(.deviceHub, Self.dialing, at: at(0))
        _ = d.appActive(false, at: at(5))
        #expect(reports(down(&d, .deviceHub, from: 10, to: 200)).isEmpty)
        var e = detector()
        _ = e.service(.deviceHub, Self.dialing, at: at(0))
        #expect(reports(e.service(.deviceHub, .notWanted(.signedOut), at: at(20))).isEmpty)
        #expect(reports(down(&e, .deviceHub, from: 25, to: 50)).isEmpty)
    }

    @Test func anOpenServiceIncidentEndsWhenTheAppGoesToTheBackground() throws {
        var d = detector()
        let open = try #require(reports(down(&d, .presence, from: 0, to: 40)).first)
        let ended = reports(d.appActive(false, at: at(50)))
        #expect(ended.map(\.id) == [open.id])
        #expect(ended.first?.endReason == .appBackgrounded)
    }

    @Test func threeDropsOfALiveSocketAreAnUnstableService() throws {
        var d = detector()
        _ = d.service(.chiefCloud, Self.live, at: at(0))
        var out: [Detector.Output] = []
        for drop in [20.0, 60, 100] {
            out += d.serviceDropped(.chiefCloud, reason: "socket ended", at: at(drop))
            out += d.service(.chiefCloud, Self.dialing, at: at(drop))
            out += d.service(.chiefCloud, Self.live, at: at(drop + 3))
            if let (key, id) = check(out) {
                out += d.reachability(macID: key, checkID: id, internet: true, service: true, at: at(drop + 4))
            }
        }
        out += d.tick(at: at(110))
        if let (key, id) = check(Array(out.suffix(1))) {
            out += d.reachability(macID: key, checkID: id, internet: true, service: true, at: at(111))
        }
        let unstable = try #require(reports(out).first)
        #expect(unstable.kind == .serviceUnstable)
        #expect(unstable.surface == .chiefCloud)
        #expect(unstable.drops == 3)
    }

    @Test func aMacIncidentHasNoSurface() {
        #expect(Detector.Surface(key: "0f3c2a9e-1111") == nil)
        #expect(Detector.Surface(key: "service:device_hub") == .deviceHub)
        #expect(Detector.Surface(key: "service:other") == nil)
    }
}

/// Several sockets of one surface (each open Cloud Chief conversation) read as one service.
@Suite struct ServiceSocketsTests {
    static let live = ConnectivityIncidentDetector.LinkState.connected(transport: "websocket")

    @Test func liveWhileAnySocketIsLiveAndADropOnlyWhenTheLastLiveOneFails() {
        var s = ServiceSockets()
        #expect(s.apply("a", .dialing).state == .trying(transport: "websocket", reason: nil, newDial: true))
        #expect(s.apply("a", .connected).state == Self.live)
        _ = s.apply("b", .connected)
        // One of two live sockets failing: the service is still live, no drop.
        let one = s.apply("a", .failed(reason: "socket ended"))
        #expect(one.state == Self.live)
        #expect(one.droppedReason == nil)
        #expect(!one.changed)
        // The last live one failing is a drop.
        let last = s.apply("b", .failed(reason: "socket ended"))
        #expect(last.droppedReason == "socket ended")
        #expect(last.state == .trying(transport: "websocket", reason: "socket ended", newDial: false))
        // A failed dial (never live) is no drop.
        #expect(s.apply("a", .failed(reason: "refused")).droppedReason == nil)
        // Every socket closed: not wanted.
        _ = s.apply("a", .closed)
        #expect(s.apply("b", .closed).state == .notWanted(.linkClosed))
    }

    @Test func aDeliberateRestartOfALiveSocketIsNoDrop() {
        var s = ServiceSockets()
        _ = s.apply("p", .connected)
        let restart = s.apply("p", .restarting)
        #expect(restart.droppedReason == nil)
        #expect(restart.state == .trying(transport: "websocket", reason: nil, newDial: false))
    }

    /// Review finding 1: close() during the welcome let `.connected` arrive after `.closed`.
    @Test func aSocketClosedMidWelcomeNeverLooksLive() {
        var s = ServiceSockets()
        _ = s.apply("a", .dialing)
        _ = s.apply("a", .closed)
        let late = s.apply("a", .connected)
        #expect(!late.changed)
        #expect(late.state == .notWanted(.linkClosed))
        // Another conversation's socket failing is then the service's state, not hidden by a phantom.
        _ = s.apply("b", .dialing)
        #expect(s.apply("b", .failed(reason: "timeout")).state == .trying(transport: "websocket", reason: "timeout", newDial: false))
    }
}

@Suite struct ConnectivityServiceReportBodyTests {
    @Test func aServiceIncidentSendsItsSurfaceAndNoMac() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let incident = ConnectivityIncidentDetector.Incident(id: "abc12345", kind: .serviceUnreachable, state: .open, startedAt: t0,
                                                             observedAt: t0.addingTimeInterval(31), macID: "service:chief_cloud",
                                                             macName: "Cloud Chief", transport: "websocket", surface: .chiefCloud)
        let app = ConnectivityIncidentApp(version: "1.2.0", build: "7", config: "TestFlight", simulator: false, model: "iPhone17,4",
                                          os: "27.2", commit: "4f1c2a9d0e")
        let body = LiveAPI.incidentBody(incident, simulations: [], app: app)
        #expect(body["kind"] as? String == "service_unreachable")
        #expect(body["surface"] as? String == "chief_cloud")
        #expect(body["mac"] == nil)
        #expect((body["app"] as? [String: Any])?["commit"] as? String == "4f1c2a9d0e")
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func aMacIncidentStillSendsItsMacAndAnAppWithoutACommitSendsNone() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let incident = ConnectivityIncidentDetector.Incident(id: "abc12345", kind: .macUnreachable, state: .open, startedAt: t0,
                                                             observedAt: t0.addingTimeInterval(31), macID: "m1", macName: "Studio")
        let app = ConnectivityIncidentApp(version: "1.2.0", build: "7", config: "TestFlight", simulator: false, model: "iPhone17,4", os: "27.2")
        let body = LiveAPI.incidentBody(incident, simulations: [], app: app)
        #expect((body["mac"] as? [String: String])?["id"] == "m1")
        #expect(body["surface"] == nil)
        #expect((body["app"] as? [String: Any])?["commit"] == nil)
    }

    @Test func onlyARealCommitIsKept() {
        #expect(ConnectivityIncidentApp.commit("4F1C2A9D0E") == "4f1c2a9d0e")
        #expect(ConnectivityIncidentApp.commit("$(CMUX_MOBILE_SOURCE_COMMIT)") == nil)
        #expect(ConnectivityIncidentApp.commit("") == nil)
        #expect(ConnectivityIncidentApp.commit("abc") == nil)
        #expect(ConnectivityIncidentApp.commit(nil) == nil)
        #expect(ConnectivityIncidentApp.commit(String(repeating: "a", count: 41)) == nil)
    }

    @Test func anOutboxFromBeforeSurfacesStillDecodes() throws {
        // An incident persisted by a build without `surface`.
        let json = #"{"id":"abc12345","kind":"mac_unreachable","state":"open","startedAt":0,"observedAt":31,"macID":"m1","macName":"Studio"}"#
        let incident = try JSONDecoder().decode(ConnectivityIncidentDetector.Incident.self, from: Data(json.utf8))
        #expect(incident.surface == nil)
        #expect(incident.kind == .macUnreachable)
    }
}

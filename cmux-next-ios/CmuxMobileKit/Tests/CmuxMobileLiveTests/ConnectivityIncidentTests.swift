@testable import CmuxMobileLive
import CmuxMobileTransport
import Foundation
import Testing

/// The connectivity incident detector reports only major trouble: a Mac unreachable for 30 s while the
/// phone's internet works and the app is in front, or a link that keeps dropping. Everything else (a slow
/// connect, a Mac asleep, the phone offline, the app in the background, links dying at wake) stays quiet.
@Suite struct ConnectivityIncidentDetectorTests {
    typealias Detector = ConnectivityIncidentDetector
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A detector in front, on Wi-Fi, with incident ids `i1`, `i2`, …
    func detector() -> Detector {
        let counter = Counter()
        var detector = Detector(makeID: { counter.next() })
        _ = detector.appActive(true, at: t0)
        _ = detector.network("wifi", at: t0)
        return detector
    }

    final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> String { lock.withLock { value += 1; return "i\(value)" } }
    }

    static let trying = Detector.LinkState.trying(transport: "wireguard", reason: nil, newDial: true)
    static func failing(_ reason: String) -> Detector.LinkState { .trying(transport: "wireguard", reason: reason, newDial: false) }

    /// The id of the check `outputs` ask for on `m1`, if any.
    func checkID(_ outputs: [Detector.Output]) -> Int? {
        for output in outputs { if case .check("m1", let id) = output { return id } }
        return nil
    }

    func reports(_ outputs: [Detector.Output]) -> [Detector.Incident] {
        outputs.compactMap { if case .report(let incident) = $0 { incident } else { nil } }
    }

    /// Drives a Mac that never connects from `start` and returns every output up to `end`, answering
    /// each check with `internet`/`service`.
    func unreachable(_ d: inout Detector, from start: TimeInterval = 20, to end: TimeInterval, internet: Bool = true,
                     service: Bool = true) -> [Detector.Output] {
        var out = d.link(macID: "m1", name: "Studio", Self.trying, at: at(start))
        var now = start
        while now < end {
            now += 5
            // A check can come from the phase change or the tick: answer whichever asks.
            let step = d.link(macID: "m1", name: "Studio", Self.failing("dial timed out"), at: at(now)) + d.tick(at: at(now))
            out += step
            if let id = checkID(step) {
                out += d.reachability(macID: "m1", checkID: id, internet: internet, service: service, at: at(now))
            }
        }
        return out
    }

    @Test func aMacUnreachableFor30sIsReportedOnceThenResolvedOnReconnect() throws {
        var d = detector()
        let early = unreachable(&d, to: 45)
        #expect(checkID(early) == nil)
        let out = unreachable(&d, from: 45, to: 60)
        let open = try #require(reports(out).first)
        #expect(open.kind == .macUnreachable)
        #expect(open.state == .open)
        #expect(open.startedAt == at(20))
        // 30 s of qualifying time after the stretch began at 20 s: the 50 s tick of the injected clock.
        #expect(open.observedAt == at(50))
        #expect(open.lastError == "dial timed out")
        #expect(open.serviceReachable == true)
        #expect(open.network == "wifi")
        #expect(open.transport == "wireguard")
        // Still down: no second report.
        let stillDown = reports(unreachable(&d, from: 60, to: 120))
        #expect(stillDown.isEmpty)
        let up = reports(d.link(macID: "m1", name: "Studio", .connected(transport: "wireguard"), at: at(130)))
        #expect(up.count == 1)
        #expect(up[0].id == open.id)
        #expect(up[0].state == .resolved)
        #expect(up[0].duration == 110)
        #expect(d.openIncidents.isEmpty)
    }

    @Test func aSlowConnectThatSucceedsIsNotReported() {
        var d = detector()
        var out = unreachable(&d, to: 45)
        out += d.link(macID: "m1", name: "Studio", .connected(transport: "wireguard"), at: at(48))
        out += d.tick(at: at(60))
        #expect(out.isEmpty)
    }

    @Test func theCheckMustFindTheInternetUpAndTheStretchRestartsWhenItIsNot() throws {
        var d = detector()
        // The phone's own internet is down (captive portal): nothing reported however long.
        let offline = unreachable(&d, to: 120, internet: false, service: false)
        #expect(reports(offline).isEmpty)
        #expect(checkID(offline) != nil)
        // The internet comes back; the Mac connects soon after: a phone outage, not a cmux one.
        var d2 = detector()
        _ = unreachable(&d2, to: 120, internet: false)
        let reconnected = reports(d2.link(macID: "m1", name: "Studio", .connected(transport: "wireguard"), at: at(125)))
        #expect(reconnected.isEmpty)
        // Still unreachable 30 s after the internet was last seen down (the check at 110): reported, and
        // its stretch starts there, not at the first failed dial.
        var d3 = detector()
        _ = unreachable(&d3, to: 120, internet: false)
        let later = reports(unreachable(&d3, from: 120, to: 160))
        let open = try #require(later.first)
        #expect(open.startedAt == at(110))
    }

    @Test func aServiceThePhoneCannotReachIsSaid() throws {
        var d = detector()
        let opened = reports(unreachable(&d, to: 60, service: false))
        let open = try #require(opened.first)
        #expect(open.serviceReachable == false)
    }

    @Test func aMacThatIsOfflineOrUnusedIsNeverReported() {
        var d = detector()
        var out = d.link(macID: "m1", name: "Studio", .notWanted(.macOffline), at: at(0))
        for second in stride(from: 5.0, through: 300, by: 5) { out += d.tick(at: at(second)) }
        out += d.link(macID: "m2", name: "Air", .notWanted(.linkClosed), at: at(0))
        for second in stride(from: 305.0, through: 600, by: 5) { out += d.tick(at: at(second)) }
        #expect(out.isEmpty)
    }

    @Test func timeInTheBackgroundOrOfflineDoesNotCount() {
        var d = detector()
        _ = d.link(macID: "m1", name: "Studio", Self.trying, at: at(0))
        _ = d.appActive(false, at: at(10))
        // Ten minutes in the background, the link never up.
        for second in stride(from: 15.0, through: 600, by: 5) {
            let out = d.tick(at: at(second))
            #expect(out.isEmpty)
        }
        _ = d.appActive(true, at: at(600))
        let at625 = d.tick(at: at(625))
        #expect(at625.isEmpty)
        let at630 = d.tick(at: at(630))
        #expect(at630.count == 1 && checkID(at630) != nil)
        // The same for a phone without a network.
        var n = detector()
        _ = n.link(macID: "m1", name: "Studio", Self.trying, at: at(0))
        _ = n.network(nil, at: at(5))
        for second in stride(from: 10.0, through: 300, by: 5) {
            let out = n.tick(at: at(second))
            #expect(out.isEmpty)
        }
    }

    @Test func theCurrentNetworkSeedsTheKindWithoutRestartingAStretch() throws {
        var d = Detector(makeID: { "i1" })
        _ = d.appActive(true, at: t0)
        _ = d.network("cellular", at: t0, changed: false)
        _ = d.link(macID: "m1", name: "Studio", Self.trying, at: at(0))
        // The path monitor reports the same network again: the stretch goes on.
        _ = d.network("cellular", at: at(20), changed: false)
        d.dialFailed(macID: "m1", reason: "the Mac didn't answer in time")
        let tick = d.tick(at: at(30))
        let id = try #require(checkID(tick))
        let opened = reports(d.reachability(macID: "m1", checkID: id, internet: true, service: true, at: at(30)))
        let open = try #require(opened.first)
        #expect(open.network == "cellular")
        #expect(open.lastError == "the Mac didn't answer in time")
        // A different kind is a change: it restarts.
        var e = Detector(makeID: { "i2" })
        _ = e.appActive(true, at: t0)
        _ = e.network("wifi", at: t0, changed: false)
        _ = e.link(macID: "m1", name: "Studio", Self.trying, at: at(0))
        _ = e.network("cellular", at: at(20), changed: false)
        let early = e.tick(at: at(30))
        #expect(checkID(early) == nil)
    }

    @Test func aNewStretchCountsOnlyItsOwnDials() throws {
        var d = detector()
        _ = unreachable(&d, to: 60)
        _ = d.appActive(false, at: at(65))
        _ = d.appActive(true, at: at(70))
        // Two more dials after the wake, then the 30 s pass.
        var out = d.link(macID: "m1", name: "Studio", Self.trying, at: at(72))
        out += d.link(macID: "m1", name: "Studio", Self.trying, at: at(90))
        let tick = d.tick(at: at(101))
        let id = try #require(checkID(out + tick))
        let opened = reports(d.reachability(macID: "m1", checkID: id, internet: true, service: true, at: at(101)))
        let open = try #require(opened.first)
        #expect(open.attempts == 2)
    }

    @Test func aNetworkChangeRestartsTheStretch() {
        var d = detector()
        _ = d.link(macID: "m1", name: "Studio", Self.trying, at: at(0))
        _ = d.network("cellular", at: at(25))
        let at50 = d.tick(at: at(50))
        #expect(at50.isEmpty)
        let at55 = d.tick(at: at(55))
        #expect(at55.count == 1 && checkID(at55) != nil)
    }

    @Test(arguments: [
        (Detector.LinkState.notWanted(.linkClosed), Detector.Incident.EndReason.linkClosed),
        (.notWanted(.signedOut), .signedOut),
    ])
    func anOpenIncidentEndsOnceWithWhy(state: Detector.LinkState, reason: Detector.Incident.EndReason) throws {
        var d = detector()
        let opened = reports(unreachable(&d, to: 60))
        let open = try #require(opened.first)
        let end = reports(d.link(macID: "m1", name: "Studio", state, at: at(70)))
        #expect(end.map(\.state) == [.ended])
        #expect(end.first?.endReason == reason)
        #expect(end.first?.id == open.id)
        let afterEnd = reports(d.link(macID: "m1", name: "Studio", .connected(transport: "wireguard"), at: at(80)))
        #expect(afterEnd.isEmpty)
    }

    @Test func aMacThatStaysOfflinePastTheGraceEndsTheIncidentWhenItLeft() throws {
        var d = detector()
        let opened = reports(unreachable(&d, to: 60))
        let open = try #require(opened.first)
        let leaving = d.link(macID: "m1", name: "Studio", .notWanted(.macOffline), at: at(70))
        #expect(reports(leaving).isEmpty)
        let inGrace = reports(d.tick(at: at(125)))
        #expect(inGrace.isEmpty)
        let ended = reports(d.tick(at: at(130)))
        #expect(ended.map(\.state) == [.ended])
        #expect(ended.first?.endReason == .macOffline)
        #expect(ended.first?.id == open.id)
        #expect(ended.first?.observedAt == at(70))
        let afterEnd = reports(d.link(macID: "m1", name: "Studio", .connected(transport: "wireguard"), at: at(140)))
        #expect(afterEnd.isEmpty)
    }

    @Test func aHostThatRestartsWithinTheGraceResolvesTheIncident() throws {
        var d = detector()
        let opened = reports(unreachable(&d, to: 60))
        let open = try #require(opened.first)
        // The host restarts: presence offline for 9 s, then it is dialed and answers.
        _ = d.link(macID: "m1", name: "Studio", .notWanted(.macOffline), at: at(70))
        _ = d.link(macID: "m1", name: "Studio", Self.trying, at: at(79))
        let resolved = reports(d.link(macID: "m1", name: "Studio", .connected(transport: "wireguard"), at: at(82)))
        #expect(resolved.map(\.state) == [.resolved])
        #expect(resolved.first?.id == open.id)
        let later = reports(d.tick(at: at(200)))
        #expect(later.isEmpty)
    }

    @Test func aMacThatRestartsOrSleepsIsNotAnUnstableLink() {
        var d = detector()
        _ = connected(&d, at: 20)
        // Each time the host is restarted the link drops and presence goes offline: the Mac went away,
        // the link did not fail. Three of these are no unstable link.
        var outputs: [Detector.Output] = []
        for at0 in [60.0, 100.0, 140.0] {
            outputs += d.dropped(macID: "m1", reason: "the link closed", at: at(at0))
            outputs += d.link(macID: "m1", name: "Studio", .notWanted(.macOffline), at: at(at0))
            outputs += d.link(macID: "m1", name: "Studio", Self.trying, at: at(at0 + 3))
            outputs += connected(&d, at: at0 + 4)
        }
        #expect(checkID(outputs) == nil)
    }

    @Test func aDropTheLinkDoesNotRecoverFromQuicklyIsNotCounted() {
        var d = detector()
        _ = connected(&d, at: 20)
        _ = drop(&d, at: 60)
        _ = drop(&d, at: 100)
        // The third drop takes 40 s to come back (a hung or asleep Mac, an unreachable stretch): not a drop
        // of an unstable link.
        var out = d.dropped(macID: "m1", reason: "probe timed out", at: at(140))
        out += d.link(macID: "m1", name: "Studio", .trying(transport: "webrtc", reason: nil, newDial: true), at: at(140))
        out += d.tick(at: at(165))
        out += connected(&d, at: 180)
        #expect(checkID(out) == nil)
    }

    @Test func oneMacHasOneOpenIncidentAtATime() throws {
        var d = detector()
        _ = connected(&d, at: 20)
        _ = drop(&d, at: 60)
        _ = drop(&d, at: 100)
        let third = drop(&d, at: 140)
        let id = try #require(checkID(third))
        let opened = reports(d.reachability(macID: "m1", checkID: id, internet: true, service: true, at: at(142)))
        #expect(opened.map(\.kind) == [.linkUnstable])
        // While it is open the Mac stops answering for good: the unstable link ends, handing over to an
        // unreachable incident, so a real outage is never hidden and one incident stays open.
        var out = d.link(macID: "m1", name: "Studio", Self.trying, at: at(200))
        var outage: [Detector.Incident] = []
        for second in stride(from: 205.0, through: 240, by: 5) {
            let step = d.tick(at: at(second))
            out += step
            if let check = checkID(step) {
                outage += reports(d.reachability(macID: "m1", checkID: check, internet: true, service: true, at: at(second)))
            }
        }
        #expect(outage.map(\.kind) == [.linkUnstable, .macUnreachable])
        #expect(outage.first?.state == .ended)
        #expect(outage.first?.endReason == .becameUnreachable)
        #expect(outage.last?.state == .open)
        #expect(d.openIncidents.count == 1)
    }

    @Test func goingToTheBackgroundOrLosingTheNetworkEndsOpenIncidents() throws {
        var d = detector()
        let openedD = reports(unreachable(&d, to: 60))
        _ = try #require(openedD.first)
        let end = reports(d.appActive(false, at: at(65)))
        #expect(end.map(\.endReason) == [.appBackgrounded])
        var n = detector()
        let openedN = reports(unreachable(&n, to: 60))
        _ = try #require(openedN.first)
        let lost = reports(n.network(nil, at: at(65)))
        #expect(lost.map(\.endReason) == [.networkLost])
    }

    // MARK: Unstable links

    func connected(_ d: inout Detector, at second: TimeInterval) -> [Detector.Output] {
        d.link(macID: "m1", name: "Studio", .connected(transport: "webrtc"), at: at(second))
    }

    /// A drop, the redial, and the link back a second later.
    func drop(_ d: inout Detector, at second: TimeInterval) -> [Detector.Output] {
        var out = d.dropped(macID: "m1", reason: "probe timed out", at: at(second))
        out += d.link(macID: "m1", name: "Studio", .trying(transport: "webrtc", reason: nil, newDial: true), at: at(second))
        out += connected(&d, at: second + 1)
        return out
    }

    @Test func threeDropsInFiveMinutesAreAnUnstableLinkThenStableTenMinutesLater() throws {
        var d = detector()
        _ = connected(&d, at: 20)
        let first = drop(&d, at: 60)
        #expect(first.isEmpty)
        let second = drop(&d, at: 120)
        #expect(second.isEmpty)
        let third = drop(&d, at: 200)
        let thirdCheck = try #require(checkID(third))
        // An answer to another (older) check is ignored.
        let stale = d.reachability(macID: "m1", checkID: thirdCheck - 1, internet: true, service: true, at: at(201))
        #expect(stale.isEmpty)
        let checked = reports(d.reachability(macID: "m1", checkID: thirdCheck, internet: true, service: true, at: at(201)))
        let open = try #require(checked.first)
        #expect(open.kind == .linkUnstable)
        #expect(open.drops == 3)
        #expect(open.startedAt == at(60))
        // More drops while it is open add nothing.
        _ = drop(&d, at: 260)
        let at300 = reports(d.tick(at: at(300)))
        #expect(at300.isEmpty)
        let at855 = reports(d.tick(at: at(855)))
        #expect(at855.isEmpty)
        let stable = reports(d.tick(at: at(860)))
        #expect(stable.map(\.state) == [.resolved])
        #expect(stable.first?.id == open.id)
        // Three more drops inside the 30-minute cooldown: not again.
        _ = drop(&d, at: 900)
        _ = drop(&d, at: 950)
        let cooled = drop(&d, at: 1000)
        #expect(checkID(cooled) == nil)
    }

    @Test func anUnstableLinkIsReportedOnlyOnceTheLinkIsUpAgain() throws {
        var d = detector()
        _ = connected(&d, at: 20)
        _ = drop(&d, at: 60)
        _ = drop(&d, at: 100)
        // The third drop, and the link is still down: nothing is asked or reported yet.
        var down = d.dropped(macID: "m1", reason: "probe timed out", at: at(140))
        down += d.link(macID: "m1", name: "Studio", .trying(transport: "webrtc", reason: nil, newDial: true), at: at(140))
        down += d.tick(at: at(145))
        #expect(checkID(down) == nil)
        // The link comes back within 20 s: the drop counts, and the unstable link is checked and reported.
        let back = d.link(macID: "m1", name: "Studio", .connected(transport: "webrtc"), at: at(150))
        let id = try #require(checkID(back))
        let opened = reports(d.reachability(macID: "m1", checkID: id, internet: true, service: true, at: at(151)))
        #expect(opened.map(\.kind) == [.linkUnstable])
    }

    @Test func anUnstableLinkTheServiceHeldAsARestartIsForgottenWithItsCooldown() throws {
        var d = detector()
        _ = connected(&d, at: 20)
        _ = drop(&d, at: 60)
        _ = drop(&d, at: 100)
        let thirdDrop = drop(&d, at: 140)
        let first = try #require(checkID(thirdDrop))
        let opened = reports(d.reachability(macID: "m1", checkID: first, internet: true, service: true, at: at(142)))
        let held = try #require(opened.first)
        d.forgetUnstable(incidentID: held.id)
        #expect(d.openIncidents.isEmpty)
        // A real run of drops right after is reported (no 30-minute cooldown from the held one).
        _ = drop(&d, at: 200)
        _ = drop(&d, at: 240)
        let sixthDrop = drop(&d, at: 280)
        let second = try #require(checkID(sixthDrop))
        let again = reports(d.reachability(macID: "m1", checkID: second, internet: true, service: true, at: at(282)))
        #expect(again.map(\.kind) == [.linkUnstable])
    }

    @Test func dropsSpreadOverMoreThanFiveMinutesAreNot() {
        var d = detector()
        _ = connected(&d, at: 20)
        var out = drop(&d, at: 30)
        out += drop(&d, at: 200)
        out += drop(&d, at: 340)
        out += d.tick(at: at(345))
        #expect(out.isEmpty)
    }

    @Test func dropsRightAfterWakeOrANetworkChangeDoNotCount() {
        var d = detector()
        _ = connected(&d, at: 20)
        var out: [Detector.Output] = []
        // Each wake kills links left from before the suspension: expected, not instability.
        for wake in [100.0, 200, 300] {
            _ = d.appActive(false, at: at(wake - 50))
            _ = d.appActive(true, at: at(wake))
            out += drop(&d, at: wake + 2)
        }
        // The same after network changes.
        for change in [400.0, 450, 500] {
            _ = d.network("cellular", at: at(change))
            out += drop(&d, at: change + 3)
        }
        #expect(out.isEmpty)
    }

    @Test func dropsWhileThePhoneIsOfflineAreNotAnIncident() throws {
        var d = detector()
        _ = connected(&d, at: 20)
        _ = drop(&d, at: 60)
        _ = drop(&d, at: 100)
        let third = drop(&d, at: 140)
        let thirdCheck = try #require(checkID(third))
        let offline = reports(d.reachability(macID: "m1", checkID: thirdCheck, internet: false, service: false, at: at(141)))
        #expect(offline.isEmpty)
        let later = reports(d.tick(at: at(160)))
        #expect(later.isEmpty)
    }
}

@Suite struct ConnectivityIncidentOutboxTests {
    typealias Incident = ConnectivityIncidentDetector.Incident
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func incident(_ id: String, _ state: Incident.State = .open) -> Incident {
        Incident(id: id, kind: .macUnreachable, state: state, startedAt: t0, observedAt: t0.addingTimeInterval(31),
                 macID: "m1", macName: "Studio")
    }

    @Test func sendsInOrderAndBacksOffTheHead() {
        var box = ConnectivityIncidentOutbox()
        box.enqueue(incident("a"), simulations: [], at: t0)
        box.enqueue(incident("a", .resolved), simulations: [], at: t0)
        let head = box.next(at: t0)
        #expect(head?.incident.state == .open)
        box.finish(.failed, at: t0)
        // The head waits out its backoff; nothing behind it jumps the queue.
        let waiting = box.next(at: t0.addingTimeInterval(4))
        #expect(waiting == nil)
        #expect(box.retryAt == t0.addingTimeInterval(5))
        let retried = box.next(at: t0.addingTimeInterval(5))
        #expect(retried?.incident.state == .open)
        box.finish(.failed, at: t0.addingTimeInterval(5))
        #expect(box.retryAt == t0.addingTimeInterval(35))
        box.finish(.sent, at: t0.addingTimeInterval(35))
        let second = box.next(at: t0.addingTimeInterval(35))
        #expect(second?.incident.state == .resolved)
        box.finish(.refused, at: t0.addingTimeInterval(35))
        #expect(box.entries.isEmpty)
        #expect(box.open.isEmpty)
    }

    @Test func dropsAReportOlderThanAWeek() {
        var box = ConnectivityIncidentOutbox()
        box.enqueue(incident("a"), simulations: [], at: t0)
        let stale = box.next(at: t0.addingTimeInterval(7 * 86_400 + 1))
        #expect(stale == nil)
    }

    @Test func aRelaunchEndsWhatTheLastLaunchLeftOpen() throws {
        var box = ConnectivityIncidentOutbox()
        box.enqueue(incident("a"), simulations: [], at: t0)
        box.finish(.sent, at: t0)
        box.open["a"]?.lastSeen = t0.addingTimeInterval(90)
        let data = try JSONEncoder().encode(box)
        var relaunched = try JSONDecoder().decode(ConnectivityIncidentOutbox.self, from: data)
        relaunched.recoverRelaunch(at: t0.addingTimeInterval(3600))
        let next = relaunched.next(at: t0.addingTimeInterval(3600))
        let ended = try #require(next)
        #expect(ended.incident.state == .ended)
        #expect(ended.incident.endReason == .appRelaunched)
        #expect(ended.incident.observedAt == t0.addingTimeInterval(90))
        #expect(relaunched.open.isEmpty)
    }
}

@MainActor
@Suite struct ConnectivityIncidentReporterTests {
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(ConnectivityIncidentDetector.Incident, [String])] = []
        var failures: [any Error] = []
        /// Notes the service answers, in order (nil: posted).
        var notes: [String?] = []
        func add(_ incident: ConnectivityIncidentDetector.Incident, _ simulations: [String]) throws -> String? {
            try lock.withLock {
                if !failures.isEmpty { throw failures.removeFirst() }
                items.append((incident, simulations))
                return notes.isEmpty ? nil : notes.removeFirst()
            }
        }
        var all: [(ConnectivityIncidentDetector.Incident, [String])] { lock.withLock { items } }
    }

    final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        func get() -> Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    final class Flag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    func reporter(team: Bool, sent: Sent, now: Now, file: URL? = nil, internet: Bool = true, teamFlag: Flag? = nil) -> ConnectivityIncidentReporter {
        let app = ConnectivityIncidentApp(version: "1.2.0", build: "7", config: "TestFlight", simulator: false, model: "iPhone17,4", os: "27.2")
        let flag = teamFlag ?? Flag(team)
        return ConnectivityIncidentReporter(file: file, app: app, now: { now.get() }, isTeam: { flag.value },
                                            check: { (internet, true) },
                                            send: { incident, simulations, _ in try sent.add(incident, simulations) })
    }

    func settle(until done: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test: waits for the reporter's send task
        }
    }

    /// The app in front, a Mac that never connects, ticks every 5 s until `seconds`.
    func driveOutage(_ r: ConnectivityIncidentReporter, now: Now, seconds: Int) async {
        r.appActive(true)
        r.link(macID: "m1", name: "Studio", .trying(transport: "wireguard", reason: nil, newDial: true))
        for _ in 0..<(seconds / 5) {
            now.advance(5)
            r.link(macID: "m1", name: "Studio", .trying(transport: "wireguard", reason: "dial timed out", newDial: false))
            r.tick()
            await Task.yield()
        }
    }

    @Test func aTeamPhoneSendsTheOpenAndTheResolve() async {
        let sent = Sent()
        let now = Now()
        let r = reporter(team: true, sent: sent, now: now)
        r.simulations = ["block_udp"]
        await driveOutage(r, now: now, seconds: 40)
        await settle { sent.all.count == 1 }
        #expect(sent.all.map(\.0.state) == [.open])
        #expect(sent.all.first?.1 == ["block_udp"])
        r.link(macID: "m1", name: "Studio", .connected(transport: "wireguard"))
        await settle { sent.all.count == 2 }
        #expect(sent.all.map(\.0.state) == [.open, .resolved])
        #expect(Set(sent.all.map(\.0.id)).count == 1)
    }

    @Test func aPhoneOutsideTheTeamNeverChecksOrSends() async {
        let sent = Sent()
        let now = Now()
        let r = reporter(team: false, sent: sent, now: now)
        await driveOutage(r, now: now, seconds: 120)
        r.link(macID: "m1", name: "Studio", .connected(transport: "wireguard"))
        for _ in 0..<100 { await Task.yield() }
        #expect(sent.all.isEmpty)
        #expect(r.pending.isEmpty)
    }

    @Test func aFailedSendIsKeptOnDiskAndSentByTheNextLaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "incidents-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sent = Sent()
        sent.failures = [URLError(.notConnectedToInternet)]
        let now = Now()
        let first = reporter(team: true, sent: sent, now: now, file: file)
        await driveOutage(first, now: now, seconds: 40)
        await settle { first.pending.first?.tries == 1 }
        #expect(first.pending.map(\.incident.state) == [.open])
        #expect(FileManager.default.fileExists(atPath: file.path))
        // The app is killed while the Mac is still unreachable; the next launch sends the start, then
        // its end as "app relaunched".
        let second = reporter(team: true, sent: sent, now: now, file: file)
        // The send lands before the outbox drops it: wait for both.
        await settle { sent.all.count == 2 && second.pending.isEmpty }
        #expect(sent.all.map(\.0.state) == [.open, .ended])
        #expect(sent.all.last?.0.endReason == .appRelaunched)
        #expect(second.pending.isEmpty)
    }

    @Test func aRelaunchEndsTheIncidentWhenItWasLastSeenNotWhenItOpened() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "incidents-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let sent = Sent()
        let now = Now()
        let first = reporter(team: true, sent: sent, now: now, file: file)
        await driveOutage(first, now: now, seconds: 40)
        await settle { sent.all.count == 1 }
        let opened = try #require(sent.all.first?.0)
        // Ten more seconds in front, then the app is killed (no end sent).
        now.advance(10)
        first.tick()
        let second = reporter(team: true, sent: sent, now: now, file: file)
        await settle { sent.all.count == 2 && second.pending.isEmpty }
        let ended = try #require(sent.all.last?.0)
        #expect(ended.endReason == .appRelaunched)
        #expect(ended.duration >= opened.duration + 10)
    }

    @Test func aReportTheServiceRefusesIsDropped() async {
        let sent = Sent()
        sent.failures = [LiveAPI.Failure(status: 403, code: "not_team", message: "no")]
        let now = Now()
        let r = reporter(team: true, sent: sent, now: now)
        await driveOutage(r, now: now, seconds: 40)
        await settle { r.pending.isEmpty }
        #expect(r.pending.isEmpty)
        #expect(sent.all.isEmpty)
    }

    @Test func anIncidentAlreadyReportedStillEndsAfterTheAudienceChanged() async {
        let sent = Sent()
        let now = Now()
        let team = Flag(true)
        let r = reporter(team: true, sent: sent, now: now, teamFlag: team)
        await driveOutage(r, now: now, seconds: 40)
        await settle { sent.all.count == 1 }
        // Sign-out sets the audience to everyone before the coordinator stops.
        team.value = false
        r.link(macID: "m1", name: "Studio", .notWanted(.signedOut))
        await settle { sent.all.count == 2 }
        #expect(sent.all.map(\.0.state) == [.open, .ended])
        #expect(sent.all.last?.0.endReason == .signedOut)
    }

    @Test func signOutSendsTheEndsBeforeItReturns() async {
        let sent = Sent()
        let now = Now()
        let r = reporter(team: true, sent: sent, now: now)
        await driveOutage(r, now: now, seconds: 40)
        await settle { sent.all.count == 1 }
        await r.signOut()
        #expect(sent.all.map(\.0.state) == [.open, .ended])
    }

    @Test func signOutEndsOpenIncidentsAsSignedOut() async {
        let sent = Sent()
        let now = Now()
        let r = reporter(team: true, sent: sent, now: now)
        await driveOutage(r, now: now, seconds: 40)
        await settle { sent.all.count == 1 }
        r.stop()
        await settle { sent.all.count == 2 }
        #expect(sent.all.last?.0.endReason == .signedOut)
    }
}

/// The link reports real drops, never deliberate redials, and the coordinator reads its phases.
@MainActor
@Suite struct ConnectivityIncidentLinkTests {
    @Test func aLiveLinkThatDiesIsADropAndAResumeIsNot() async {
        let controller = LinkController(transport: .webRTC, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://api.example")!, teamID: "team-1", deviceID: "d", macDeviceID: $0) }
        var signals: [LinkController.LinkSignal] = []
        controller.onSignal = { signals.append($0) }
        controller.send(.target(LinkMachine.Target(macID: "mac-1", name: "Mac", isOnline: true)))
        let deadline = ContinuousClock.now + .seconds(10)
        while !controller.phase.isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test: waits for the mock dial
        }
        #expect(controller.phase.isConnected)
        // A deliberate redial (back from the background) is no drop.
        controller.send(.background)
        controller.send(.resume)
        #expect(!signals.contains { if case .dropped = $0 { true } else { false } })
        while !controller.phase.isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test: waits for the redial
        }
        // A transport switch redials on purpose: no drop either.
        controller.send(.transport(.wireGuard))
        #expect(!signals.contains { if case .dropped = $0 { true } else { false } })
        while !controller.phase.isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5)) // test: waits for the redial on the new transport
        }
        controller.send(.linkDropped(generation: controller.dialGeneration, reason: "stream ended"))
        #expect(signals.contains(.dropped(reason: "stream ended")))
        #expect(signals.contains { if case .phase(.connecting) = $0 { true } else { false } })
    }

    #if os(iOS)
    @Test func phasesMapToTheDetectorsStates() {
        #expect(LiveCoordinator.incidentState(.idle) == .notWanted(.linkClosed))
        #expect(LiveCoordinator.incidentState(.macOffline) == .notWanted(.macOffline))
        #expect(LiveCoordinator.incidentState(.signedOut) == .notWanted(.signedOut))
        #expect(LiveCoordinator.incidentState(.connecting(.wireGuard, attempt: 2)) == .trying(transport: "wireguard", reason: nil, newDial: true))
        #expect(LiveCoordinator.incidentState(.waiting(.webRTC, attempt: 3, reason: "x", retryIn: .seconds(4)))
            == .trying(transport: "webrtc", reason: "x", newDial: false))
        #expect(LiveCoordinator.incidentState(.connected(.webRTC, .direct, rttMillis: 3)) == .connected(transport: "webrtc"))
        #expect(LiveCoordinator.networkKind("en0,pdp_ip0 via 192.168.1.1") == "wifi")
        #expect(LiveCoordinator.networkKind("pdp_ip0 via 10.0.0.1") == "cellular")
        #expect(LiveCoordinator.networkKind("utun3 via -") == "other")
        #expect(LiveCoordinator.simulations(relayOnly: true, blockUDP: true) == ["relay_only", "block_udp"])
    }
    #endif

    @Test func theReportBodyIsWhatTheServiceReads() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var incident = ConnectivityIncidentDetector.Incident(id: "abc12345", kind: .macUnreachable, state: .ended, startedAt: t0,
                                                             observedAt: t0.addingTimeInterval(31.25), macID: "m1", macName: "Studio",
                                                             attempts: 4, lastError: "timeout", transport: "wireguard",
                                                             serviceReachable: false, network: "wifi")
        incident.endReason = .networkLost
        let app = ConnectivityIncidentApp(version: "1.2.0", build: "7", config: "TestFlight", simulator: true, model: "iPhone17,4", os: "27.2")
        let body = LiveAPI.incidentBody(incident, simulations: ["relay_only"], app: app)
        #expect(body["kind"] as? String == "mac_unreachable")
        #expect(body["state"] as? String == "ended")
        #expect(body["endReason"] as? String == "network_lost")
        #expect(body["durationMs"] as? Int == 31_250)
        #expect(body["startedAt"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(body["serviceReachable"] as? Bool == false)
        #expect((body["app"] as? [String: Any])?["simulator"] as? Bool == true)
        #expect(body["simulations"] as? [String] == ["relay_only"])
        #expect(JSONSerialization.isValidJSONObject(body))
    }
}

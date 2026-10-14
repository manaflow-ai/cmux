import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import Testing

@Suite struct CloudTerminalSizingRelayTests {
    private func phone(cols: Int = 50) -> TerminalSizingParticipant {
        TerminalSizingParticipant(id: "ignored", userID: "u_me", deviceKind: .iphone, deviceName: "iPhone", viewport: TerminalGridSize(cols: cols, rows: 30))
    }

    @Test func capabilityGatesSupport() {
        var relay = CloudTerminalSizingRelay()
        relay.connectionStarted(capabilities: ["attach-initial-size"])
        #expect(!relay.isSupported)
        relay.connectionStarted(capabilities: [CloudTerminalSizingRelay.capability])
        #expect(relay.isSupported)
    }

    @Test func phoneReportsDeduplicateAndCarryTheViewKey() {
        var relay = CloudTerminalSizingRelay()
        relay.attached(selfParticipantID: "c7")
        let first = relay.phoneReported(clientID: "p1", participant: phone())
        #expect(first?.view == "mobile:p1")
        #expect(first?.participant.via == "c7")
        let repeated = relay.phoneReported(clientID: "p1", participant: phone())
        #expect(repeated == nil)
        let resized = relay.phoneReported(clientID: "p1", participant: phone(cols: 60))
        #expect(resized != nil)
    }

    @Test func disconnectedByForTheMirrorDetachesEveryPhoneBehindIt() throws {
        var relay = CloudTerminalSizingRelay()
        relay.attached(selfParticipantID: "c7")
        _ = relay.phoneReported(clientID: "p1", participant: phone())
        _ = relay.phoneReported(clientID: "p2", participant: phone())
        relay.noteHostParticipant("c7/mobile:p1", forView: "mobile:p1")
        let actor = TerminalDetachActor(userID: "u_kai", displayName: "Kai", deviceName: "MacBook")
        let routed = relay.routeDetached(reason: .disconnectedBy(actor), view: nil)
        let route = try #require(routed)
        guard case let .mirror(reason, phoneClientIDs) = route else {
            Issue.record("expected the mirror route, got \(route)")
            return
        }
        #expect(reason == .disconnectedBy(actor))
        #expect(!reason.reconnectsAutomatically)
        // The phones lost their path to the terminal with this Mac.
        #expect(phoneClientIDs.sorted() == ["p1", "p2"])
        #expect(relay.views.isEmpty)
        #expect(relay.hostParticipantID(clientID: "p1") == nil)
        #expect(!relay.awaitsHost(clientID: "p1", now: Date()))

        // After the Mac reattaches, a phone that reattaches is relayed anew.
        relay.attached(selfParticipantID: "c8")
        let rejoined = relay.phoneReported(clientID: "p1", participant: phone())
        #expect(rejoined?.view == "mobile:p1")
        #expect(rejoined?.participant.via == "c8")
    }

    /// A view-only detach (a phone disconnected this Mac's view) keeps the
    /// relay: every phone stays relayed and keeps its host participant.
    @Test func viewOnlyDetachOfTheMirrorKeepsEveryPhoneRelayed() {
        var relay = CloudTerminalSizingRelay()
        relay.connectionStarted(capabilities: [CloudTerminalSizingRelay.capability, CloudTerminalSizingRelay.viewDetachCapability])
        #expect(relay.supportsViewDetach)
        relay.attached(selfParticipantID: "c7")
        _ = relay.phoneReported(clientID: "p1", participant: phone())
        relay.noteHostParticipant("c7/mobile:p1", forView: "mobile:p1")
        let actor = TerminalDetachActor(displayName: "Maya", deviceName: "Maya's iPhone")
        let route = relay.routeDetached(reason: .disconnectedBy(actor), view: nil, viewOnly: true)
        #expect(route == .ownView(.disconnectedBy(actor)))
        #expect(relay.views.count == 1)
        #expect(relay.hostParticipantID(clientID: "p1") == "c7/mobile:p1")
    }

    @Test func aNetworkDropOfTheMirrorKeepsItsPhones() {
        var relay = CloudTerminalSizingRelay()
        _ = relay.phoneReported(clientID: "p1", participant: phone())
        let route = relay.routeDetached(reason: .network, view: nil)
        #expect(route == .mirror(.network, phoneClientIDs: []))
        #expect(relay.views.count == 1)
    }

    @Test func phoneDetachIsForwardedToThatPhoneOnly() {
        var relay = CloudTerminalSizingRelay()
        _ = relay.phoneReported(clientID: "p1", participant: phone())
        _ = relay.phoneReported(clientID: "p2", participant: phone())
        relay.noteHostParticipant("h9", forView: "mobile:p1")
        #expect(relay.hostParticipantID(clientID: "p1") == "h9")
        #expect(relay.view(forHostParticipant: "h9") == "mobile:p1")
        let route = relay.routeDetached(reason: .disconnectedBy(nil), view: "mobile:p1")
        #expect(route == .phone(clientID: "p1", reason: .disconnectedBy(nil)))
        #expect(relay.views.keys.sorted() == ["mobile:p2"])
        let unknown = relay.routeDetached(reason: .network, view: "mobile:gone")
        #expect(unknown == nil)
    }

    @Test func reconnectKeepsPhonesButForgetsHostIDs() {
        var relay = CloudTerminalSizingRelay()
        _ = relay.phoneReported(clientID: "p1", participant: phone())
        relay.noteHostParticipant("h9", forView: "mobile:p1")
        relay.receive(TerminalSizingState(generation: 3, cols: 80, rows: 24, reason: .latest, owners: [], policy: .latest, participants: []))
        relay.connectionStarted(capabilities: [CloudTerminalSizingRelay.capability])
        #expect(relay.state == nil)
        #expect(relay.hostParticipantID(clientID: "p1") == nil)
        #expect(relay.views.count == 1)
    }

    @Test func staleStateGenerationsAreIgnored() {
        var relay = CloudTerminalSizingRelay()
        let s5 = TerminalSizingState(generation: 5, cols: 80, rows: 24, reason: .latest, owners: [], policy: .latest, participants: [])
        var s4 = s5; s4.generation = 4; s4.cols = 10
        let first = relay.receive(s5)
        let stale = relay.receive(s4)
        let same = relay.receive(s5)
        #expect(first && !stale && !same)
    }

    @Test func aJoiningPhoneAwaitsTheHostUntilItsStateShowsTheViewport() throws {
        var relay = CloudTerminalSizingRelay()
        relay.connectionStarted(capabilities: [CloudTerminalSizingRelay.capability])
        relay.attached(selfParticipantID: "c7")
        let sent = Date(timeIntervalSince1970: 100)
        let reported = relay.phoneReported(clientID: "p1", participant: phone(cols: 50))
        let view = try #require(reported)
        #expect(!relay.awaitsHost(clientID: "p1", now: sent))
        relay.reportSent(view: view.view, at: sent)
        #expect(relay.awaitsHost(clientID: "p1", now: sent))

        // The host named the view, but its state still predates the report.
        relay.noteHostParticipant("c7/mobile:p1", forView: view.view)
        #expect(relay.awaitsHost(clientID: "p1", now: sent.addingTimeInterval(0.1)))

        var engine = TerminalSizingEngine(initialSize: TerminalGridSize(cols: 120, rows: 40))
        _ = engine.attach(TerminalSizingParticipant(id: "c7", deviceKind: .mac, viewport: TerminalGridSize(cols: 120, rows: 40)))
        relay.receive(engine.state)
        #expect(relay.awaitsHost(clientID: "p1", now: sent.addingTimeInterval(0.1)))

        var joined = phone(cols: 50)
        joined.id = "c7/mobile:p1"
        _ = engine.attach(joined)
        relay.receive(engine.state)
        #expect(engine.state.size == TerminalGridSize(cols: 50, rows: 30))
        #expect(!relay.awaitsHost(clientID: "p1", now: sent.addingTimeInterval(0.1)))
    }

    @Test func aLostHostAnswerStopsBlockingAfterTheTimeout() throws {
        var relay = CloudTerminalSizingRelay()
        relay.connectionStarted(capabilities: [CloudTerminalSizingRelay.capability])
        let sent = Date(timeIntervalSince1970: 100)
        let reported = relay.phoneReported(clientID: "p1", participant: phone())
        let view = try #require(reported)
        relay.reportSent(view: view.view, at: sent)
        #expect(relay.awaitsHost(clientID: "p1", now: sent.addingTimeInterval(CloudTerminalSizingRelay.hostReportTimeout - 0.1)))
        #expect(!relay.awaitsHost(clientID: "p1", now: sent.addingTimeInterval(CloudTerminalSizingRelay.hostReportTimeout)))
        relay.connectionStarted(capabilities: [CloudTerminalSizingRelay.capability])
        #expect(!relay.awaitsHost(clientID: "p1", now: sent))
    }
}

import CmuxTerminalSharing
import CmuxTerminalSizing
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

    @Test func disconnectedByForTheMirrorDoesNotTouchPhones() {
        var relay = CloudTerminalSizingRelay()
        _ = relay.phoneReported(clientID: "p1", participant: phone())
        let route = relay.routeDetached(reason: .disconnectedBy(nil), view: nil)
        #expect(route == .mirror(.disconnectedBy(nil)))
        #expect(route.map { if case let .mirror(reason) = $0 { return reason.reconnectsAutomatically } else { return true } } == false)
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
}

import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import Testing

@Suite struct LocalTerminalSizingHostTests {
    private let me = TerminalSharingIdentity(userID: "u_me", displayName: "Me", deviceName: "Mac")

    private func host(
        mac: TerminalGridSize = TerminalGridSize(cols: 200, rows: 60),
        policy: TerminalSizingPolicy = .latest
    ) -> LocalTerminalSizingHost {
        LocalTerminalSizingHost(
            macParticipant: me.participant(id: "mac:pane", deviceKind: .mac, viewport: mac),
            initialSize: mac,
            policy: policy
        )
    }

    private func phone(_ client: String, user: String? = "u_me", cols: Int = 50, rows: Int = 30) -> TerminalSizingParticipant {
        TerminalSizingParticipant(
            id: LocalTerminalSizingHost.phoneParticipantID(clientID: client),
            userID: user, deviceKind: .iphone, deviceName: "iPhone",
            viewport: TerminalGridSize(cols: cols, rows: rows)
        )
    }

    @Test func defaultFitsEveryoneIncludingMyPhone() {
        var h = host(policy: .fitEveryone)
        h.syncPhones([phone("a")])
        #expect(h.state.participant("mobile:a")?.counts == true)
        #expect(h.applyTarget == .grid(TerminalGridSize(cols: 50, rows: 30)))
    }

    @Test func macAloneIsUncapped() {
        #expect(host().applyTarget == .uncapped)
    }

    @Test func sameUserPhoneDefersToMacSoTheMacStaysUncapped() {
        var h = host()
        h.syncPhones([phone("a")])
        #expect(h.state.participant("mobile:a")?.counts == false)
        #expect(h.applyTarget == .uncapped)
    }

    @Test func otherUserPhoneTakesTheGridByLatestActivity() {
        var h = host()
        h.syncPhones([phone("a", user: "u_other")])
        #expect(h.applyTarget == .grid(TerminalGridSize(cols: 50, rows: 30)))
        h.noteActivity("mac:pane")
        #expect(h.applyTarget == .uncapped)
    }

    @Test func smallestPolicyReplacesTheLegacyMinimum() {
        var h = host()
        h.setPolicy(TerminalSizingPolicy(mode: .smallest))
        h.syncPhones([phone("a", cols: 80, rows: 70), phone("b", user: "u_b", cols: 90, rows: 20)])
        h.setCountsOverride("mobile:a", true)
        #expect(h.applyTarget == .grid(TerminalGridSize(cols: 80, rows: 20)))
    }

    @Test func disconnectBlocksReportsUntilReattachAsViewer() {
        var h = host()
        h.syncPhones([phone("a", user: "u_other")])
        let detachment = TerminalSharingDetachment(reason: .disconnectedBy(me.detachActor), at: Date(timeIntervalSince1970: 0))
        let disconnected = h.disconnect("mobile:a", detachment: detachment)
        #expect(disconnected)
        #expect(h.isDetached("mobile:a"))
        h.syncPhones([phone("a", user: "u_other")])
        #expect(h.state.participant("mobile:a") == nil)
        #expect(h.applyTarget == .uncapped)
        h.reattach("mobile:a", asViewer: true)
        h.syncPhones([phone("a", user: "u_other")])
        #expect(h.state.participant("mobile:a")?.participant.countsOverride == false)
        #expect(h.applyTarget == .uncapped)
    }

    @Test func macCannotBeDisconnectedFromItsOwnHost() {
        var h = host()
        let detachment = TerminalSharingDetachment(reason: .disconnectedBy(nil), at: Date())
        let disconnected = h.disconnect("mac:pane", detachment: detachment)
        #expect(!disconnected)
    }

    @Test func droppedPhoneLeavesAndGridFollowsTheMacPane() {
        var h = host()
        h.syncPhones([phone("a", user: "u_other")])
        h.syncPhones([])
        #expect(h.phoneParticipantIDs.isEmpty)
        h.updateMacViewport(TerminalGridSize(cols: 150, rows: 40))
        #expect(h.state.size == TerminalGridSize(cols: 150, rows: 40))
        #expect(h.applyTarget == .uncapped)
    }
}

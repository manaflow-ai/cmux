import CmuxTerminalSharing
import CmuxTerminalSizing
import Testing

/// Label and visibility rules shared by the tab accessory, pane chip and panel.
@Suite struct TerminalSharingPresentationTests {
    private static let me = TerminalSizingParticipant(
        id: "mac:1", userID: "u_me", displayName: "Lawrence Chen", deviceKind: .mac,
        deviceName: "Lawrence's MacBook Pro", viewport: TerminalGridSize(cols: 100, rows: 30)
    )
    private static let maya = TerminalSizingParticipant(
        id: "c3", userID: "u_maya", displayName: "Maya Ortiz", deviceKind: .mac,
        deviceName: "Mac Studio", viewport: TerminalGridSize(cols: 118, rows: 38)
    )

    private func presentation(
        _ participants: [TerminalSizingParticipant],
        policy: TerminalSizingPolicy = .latest,
        active: String? = nil
    ) -> TerminalSharingPresentation {
        var engine = TerminalSizingEngine(initialSize: TerminalGridSize(cols: 80, rows: 24), policy: policy)
        for participant in participants { _ = engine.attach(participant) }
        if let active { _ = engine.noteActivity(active) }
        let snapshot = TerminalSharingSnapshot(state: engine.state, selfParticipantID: Self.me.id, isCloud: false)
        return TerminalSharingPresentation(snapshot: snapshot, strings: .english)
    }

    @Test func tabAccessoryOnlyWhileSomeoneElseIsAttached() {
        let alone = presentation([Self.me], policy: TerminalSizingPolicy(mode: .fixed, fixed: TerminalGridSize(cols: 70, rows: 20)))
        #expect(alone.snapshot.showsSizingChrome)
        #expect(!alone.showsTabAccessory)
        #expect(alone.tabAccessoryParticipants.isEmpty)

        let shared = presentation([Self.me, Self.maya], active: Self.maya.id)
        #expect(shared.showsTabAccessory)
        #expect(shared.tabAccessoryParticipants.map(\.id) == [Self.maya.id, Self.me.id])
    }

    @Test func ownerLabelNamesThePersonsDevice() {
        let shared = presentation([Self.me, Self.maya], active: Self.maya.id)
        #expect(shared.ownerLabel == "Maya's Mac")
        #expect(shared.tabAccessoryTooltip == "Size set by Maya's Mac · 118×38")

        let mine = presentation([Self.me, Self.maya], active: Self.me.id)
        #expect(mine.ownerLabel == "This Mac")
    }

    @Test func ownerLabelWithoutASingleOwnerDescribesThePolicy() {
        let fixed = presentation([Self.me, Self.maya], policy: TerminalSizingPolicy(mode: .fixed, fixed: TerminalGridSize(cols: 90, rows: 30)))
        #expect(fixed.ownerLabel == "Fixed")
        #expect(fixed.tabAccessoryTooltip == "Fixed · 90×30")
    }

    @Test func chipTextAddsHiddenColumnsOnlyWhenCut() {
        let shared = presentation([Self.me, Self.maya], active: Self.maya.id)
        #expect(shared.chipText(hiddenColumns: 0) == "118×38 · Maya's Mac")
        #expect(shared.chipText(hiddenColumns: 18) == "118×38 · Maya's Mac · 18 cols hidden")
    }

    @Test func participantRowsNameThisMacAndPersonDevice() {
        let shared = presentation([Self.me, Self.maya])
        #expect(shared.participantLabel(for: Self.me) == "This Mac")
        #expect(shared.participantLabel(for: Self.maya) == "Maya Ortiz · Mac Studio")
        let phone = TerminalSizingParticipant(id: "mobile:1", deviceKind: .iphone)
        #expect(shared.participantLabel(for: phone) == "iPhone")
        #expect(shared.ownerName(for: phone) == "iPhone")
        #expect(shared.initials(for: phone) == "I")
        #expect(shared.initials(for: Self.maya) == "MO")
    }

    @Test func priorityModeOrdersPanelRows() {
        let policy = TerminalSizingPolicy(mode: .priority, priority: [Self.maya.priorityKey, Self.me.priorityKey])
        let shared = presentation([Self.me, Self.maya], policy: policy)
        #expect(shared.panelParticipants.map(\.id) == [Self.maya.id, Self.me.id])
        #expect(shared.canDisconnectOthers)
    }
}

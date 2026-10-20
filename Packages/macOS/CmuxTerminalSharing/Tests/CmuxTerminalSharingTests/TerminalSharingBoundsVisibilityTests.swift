import CmuxTerminalSharing
import CmuxTerminalSizing
import Testing

/// The bounds must be visible whenever this view does not show the whole grid
/// exactly, even when nobody else is attached.
@Suite struct TerminalSharingBoundsVisibilityTests {
    private func snapshot(policy: TerminalSizingPolicy) -> TerminalSharingSnapshot {
        var engine = TerminalSizingEngine(initialSize: TerminalGridSize(cols: 120, rows: 40), policy: policy)
        engine.attach(TerminalSizingParticipant(id: "mac:1", userID: "u_me", deviceKind: .mac,
                                                viewport: TerminalGridSize(cols: 120, rows: 40)))
        return TerminalSharingSnapshot(state: engine.state, selfParticipantID: "mac:1", isCloud: false)
    }

    @Test func aloneAtMyOwnSizeShowsNoChrome() {
        #expect(!snapshot(policy: .latest).showsSizingChrome)
    }

    @Test func aloneWithASmallerFixedGridShowsTheBounds() {
        let fixed = snapshot(policy: TerminalSizingPolicy(mode: .fixed, fixed: TerminalGridSize(cols: 70, rows: 20)))
        #expect(!fixed.isShared)
        #expect(fixed.showsSizingChrome)
    }
}

/// The grid bounds and chip describe a mismatch between this view and the
/// grid. When someone else is attached but this Mac shows the grid exactly,
/// only the tab accessory appears, never the "105×45 · This Mac" chip.
@Suite struct TerminalSharingBoundsChromeTests {
    private func sharedSnapshot(phoneViewport: TerminalGridSize, policy: TerminalSizingPolicy) -> TerminalSharingSnapshot {
        var engine = TerminalSizingEngine(initialSize: TerminalGridSize(cols: 105, rows: 45), policy: policy)
        engine.attach(TerminalSizingParticipant(id: "mac:1", userID: "u_me", deviceKind: .mac,
                                                viewport: TerminalGridSize(cols: 105, rows: 45)))
        engine.attach(TerminalSizingParticipant(id: "mobile:p", userID: "u_me", deviceKind: .iphone,
                                                viewport: phoneViewport))
        return TerminalSharingSnapshot(state: engine.state, selfParticipantID: "mac:1", isCloud: false)
    }

    @Test func sharedButMatchingTheGridShowsTheTabButNoBounds() {
        let snapshot = sharedSnapshot(phoneViewport: TerminalGridSize(cols: 66, rows: 45), policy: .latest)
        #expect(snapshot.state.size == TerminalGridSize(cols: 105, rows: 45))
        #expect(snapshot.showsSizingChrome, "the tab accessory shows while a phone is attached")
        #expect(!snapshot.showsBoundsChrome, "no border or chip when this Mac shows the grid exactly")
    }

    @Test func sharedAndSmallerThanTheMacShowsTheBounds() {
        let snapshot = sharedSnapshot(phoneViewport: TerminalGridSize(cols: 66, rows: 45),
                                      policy: TerminalSizingPolicy(mode: .smallest))
        #expect(snapshot.state.size == TerminalGridSize(cols: 66, rows: 45))
        #expect(snapshot.showsBoundsChrome)
    }

    @Test func aloneWithADifferentGridShowsTheBounds() {
        var engine = TerminalSizingEngine(
            initialSize: TerminalGridSize(cols: 105, rows: 45),
            policy: TerminalSizingPolicy(mode: .fixed, fixed: TerminalGridSize(cols: 70, rows: 20))
        )
        engine.attach(TerminalSizingParticipant(id: "mac:1", userID: "u_me", deviceKind: .mac,
                                                viewport: TerminalGridSize(cols: 105, rows: 45)))
        let snapshot = TerminalSharingSnapshot(state: engine.state, selfParticipantID: "mac:1", isCloud: false)
        #expect(snapshot.showsBoundsChrome)
    }
}

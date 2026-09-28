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

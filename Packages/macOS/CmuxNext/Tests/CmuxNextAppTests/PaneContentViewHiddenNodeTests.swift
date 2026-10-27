import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextWakeups
import Testing

/// p06-scheduler-302 (R-obs, R-appear): a pane's own views follow their inputs through
/// `VisibleObservation` on the pane's visibility node. A hidden (parked, background-workspace) pane
/// reads nothing for a change and catches up once, in the turn it shows. Its agent tag was an
/// unclassed `ObservationStream` loop that kept reading while the pane was hidden.
@MainActor
struct PaneContentViewHiddenNodeTests {
    private static let presence = TabPresence(colorKey: "session-1", summary: "Claude Code · Editing app.rs:42")

    private func pane(_ model: TabStripModel, node: VisibilityNode) -> PaneContentView {
        PaneContentView.testing(stripModel: model, reveal: LaunchReveal(deadline: .zero), node: node)
    }

    @Test func aVisiblePaneShowsItsAgentTagFromTheFirstRead() {
        var tab = TabItem(id: TabID("a"), title: "a")
        tab.presence = Self.presence
        let pane = pane(TabStripModel(tabs: [tab], selectedID: TabID("a")), node: VisibilityNode(root: "pane", own: .visible))
        #expect(pane.agentTag.presence == Self.presence, "the first value applies in the pane's own init")
    }

    @Test func aHiddenPaneReadsItsAgentTagOnlyWhenItShows() {
        let node = VisibilityNode(root: "pane", own: .visible)
        let model = TabStripModel(tabs: [TabItem(id: TabID("a"), title: "a")], selectedID: TabID("a"))
        let pane = pane(model, node: node)
        #expect(pane.agentTag.presence == nil)
        node.set(.hidden)
        var tab = TabItem(id: TabID("a"), title: "a")
        tab.presence = Self.presence
        model.tabs = [tab]
        #expect(pane.agentTag.presence == nil, "a hidden pane's tag applied a change")
        node.set(.visible)
        #expect(pane.agentTag.presence == Self.presence, "the pane did not read its tag in the show turn")
    }

    @Test func appearanceChangesOfAHiddenPaneRepaintOnceOnShow() {
        let node = VisibilityNode(root: "pane", own: .hidden)
        let pane = pane(TabStripModel(tabs: [TabItem(id: TabID("a"), title: "a")]), node: node)
        let before = node.deferredCount
        for _ in 0..<3 { pane.viewDidChangeEffectiveAppearance() }
        #expect(node.deferredCount == before + 1, "a hidden pane repainted per change instead of once on show")
        node.set(.visible)
        #expect(node.deferredCount == 0, "the shown pane did not repaint for the changes it missed")
        pane.viewDidChangeEffectiveAppearance()
        #expect(node.deferredCount == 0, "a visible pane deferred its repaint")
    }
}

import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextInput
import CmuxNextTabs
import CmuxNextWakeups

/// Strips and panes for tests that never dispatch through the app's input tap: each gets a fresh
/// `InputEventTap`, so production call sites keep the tap as a required dependency.
extension TabStripView {
    @MainActor static func testing(model: TabStripModel) -> TabStripView {
        TabStripView(model: model, input: InputEventTap())
    }
}

extension PaneContentView {
    /// A pane under `node` (a visible root by default) with its own schedulers: its observations
    /// apply in the test's turn and follow changes while the node is visible.
    @MainActor static func testing(stripModel: TabStripModel, reveal: LaunchReveal,
                                   node: VisibilityNode = VisibilityNode(root: "pane:test", own: .visible),
                                   work: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget())) -> PaneContentView {
        PaneContentView(stripModel: stripModel, reveal: reveal, input: InputEventTap(), node: node,
                        deadlines: MainDeadlineScheduler(work: work))
    }
}

import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextInput
import CmuxNextTabs

/// Strips and panes for tests that never dispatch through the app's input tap: each gets a fresh
/// `InputEventTap`, so production call sites keep the tap as a required dependency.
extension TabStripView {
    @MainActor static func testing(model: TabStripModel) -> TabStripView {
        TabStripView(model: model, input: InputEventTap())
    }
}

extension PaneContentView {
    @MainActor static func testing(stripModel: TabStripModel, reveal: LaunchReveal) -> PaneContentView {
        PaneContentView(stripModel: stripModel, reveal: reveal, input: InputEventTap())
    }
}

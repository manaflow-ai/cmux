@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextTabs

extension PaneContentView {
    /// A pane over its own empty tab icon caches, for tests that check one pane alone.
    convenience init(stripModel: TabStripModel, reveal: LaunchReveal = .shared) {
        self.init(stripModel: stripModel, iconCaches: TabIconCaches(), reveal: reveal)
    }
}

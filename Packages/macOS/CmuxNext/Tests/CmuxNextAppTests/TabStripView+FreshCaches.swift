@testable import CmuxNextTabs

extension TabStripView {
    /// A strip over its own empty icon caches, for tests that check one strip alone.
    convenience init(model: TabStripModel, background: Background = .none) {
        self.init(model: model, background: background, iconCaches: TabIconCaches())
    }
}

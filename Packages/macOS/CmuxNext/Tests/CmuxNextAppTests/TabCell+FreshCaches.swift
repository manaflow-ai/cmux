@testable import CmuxNextTabs

extension TabCell {
    /// A cell over its own empty icon caches, for tests that check one cell alone.
    convenience init(item: TabItem) {
        self.init(item: item, iconCaches: TabIconCaches())
    }
}

@testable import CmuxNextTabs

extension TabGroupChipCell {
    /// A chip over its own empty icon caches, for tests that check one chip alone.
    convenience init(group: TabGroupItem, memberCount: Int) {
        self.init(group: group, memberCount: memberCount, iconCaches: TabIconCaches())
    }
}

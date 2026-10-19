import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceUnreadStateTests {
    @Test func readRowsAlwaysKnowTheirCountIsZero() {
        let preview = MobileWorkspacePreview(id: "ws", name: "ws", terminals: [])
        #expect(preview.unreadState == .read)
        #expect(preview.unreadState.count == 0)
    }

    @Test func unreadWithoutCountStaysUnknown() {
        var preview = MobileWorkspacePreview(id: "ws", name: "ws", terminals: [])
        preview.hasUnread = true
        #expect(preview.unreadState == MobileWorkspaceUnreadState(isUnread: true, count: nil))
    }

    @Test func unreadWithCountCarriesIt() {
        var preview = MobileWorkspacePreview(id: "ws", name: "ws", terminals: [])
        preview.hasUnread = true
        preview.unreadCount = 7
        #expect(preview.unreadState == MobileWorkspaceUnreadState(isUnread: true, count: 7))
    }

    @Test func mergingSumsKnownCounts() {
        let merged = MobileWorkspaceUnreadState(isUnread: true, count: 2)
            .merging(MobileWorkspaceUnreadState(isUnread: true, count: 3))
            .merging(.read)
        #expect(merged == MobileWorkspaceUnreadState(isUnread: true, count: 5))
    }

    @Test func mergingUnknownCountPoisonsTheSum() {
        let merged = MobileWorkspaceUnreadState(isUnread: true, count: 2)
            .merging(MobileWorkspaceUnreadState(isUnread: true, count: nil))
        #expect(merged == MobileWorkspaceUnreadState(isUnread: true, count: nil))
    }
}

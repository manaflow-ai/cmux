import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceListFilterTests {
    private func workspace(hasUnread: Bool) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: hasUnread ? "unread" : "read"),
            name: "ws",
            hasUnread: hasUnread,
            terminals: []
        )
    }

    @Test func allMatchesEverything() {
        #expect(MobileWorkspaceListFilter.all.matches(workspace(hasUnread: false)))
        #expect(MobileWorkspaceListFilter.all.matches(workspace(hasUnread: true)))
        #expect(!MobileWorkspaceListFilter.all.isActive)
    }

    @Test func unreadMatchesOnlyUnreadWorkspaces() {
        #expect(MobileWorkspaceListFilter.unread.matches(workspace(hasUnread: true)))
        #expect(!MobileWorkspaceListFilter.unread.matches(workspace(hasUnread: false)))
        #expect(MobileWorkspaceListFilter.unread.isActive)
    }
}

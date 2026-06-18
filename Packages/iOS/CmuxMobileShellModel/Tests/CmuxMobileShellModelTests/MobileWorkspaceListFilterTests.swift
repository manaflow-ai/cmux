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

    /// The exact narrowing both list surfaces apply (`workspaces.filter(filter.matches)`):
    /// unread keeps only unread rows, in order; all is the identity.
    @Test func filteringNarrowsAWorkspaceArray() {
        let rows = [workspace(hasUnread: false), workspace(hasUnread: true)]
        #expect(rows.filter { MobileWorkspaceListFilter.unread.matches($0) }.map(\.id.rawValue) == ["unread"])
        #expect(rows.filter { MobileWorkspaceListFilter.all.matches($0) }.count == rows.count)
    }
}

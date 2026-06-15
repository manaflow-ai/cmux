import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileWorkspaceListEmptyStateTests {
    @Test func noWorkspacesWinsBeforeSearchOrFilter() {
        #expect(
            MobileWorkspaceListEmptyState.state(
                workspaceCount: 0,
                visibleWorkspaceCount: 0,
                queryMatchedWorkspaceCount: 0,
                trimmedQuery: "build",
                filter: .unread
            ) == .noWorkspaces
        )
    }

    @Test func visibleRowsSuppressEmptyState() {
        #expect(
            MobileWorkspaceListEmptyState.state(
                workspaceCount: 4,
                visibleWorkspaceCount: 1,
                queryMatchedWorkspaceCount: 3,
                trimmedQuery: "build",
                filter: .unread
            ) == nil
        )
    }

    @Test func searchNoMatchesWinsWhenQueryIsPresent() {
        #expect(
            MobileWorkspaceListEmptyState.state(
                workspaceCount: 4,
                visibleWorkspaceCount: 0,
                queryMatchedWorkspaceCount: 0,
                trimmedQuery: "release",
                filter: .unread
            ) == .noSearchResults
        )
    }

    @Test func filterNoMatchesWinsWhenFilterHidesSearchMatches() {
        #expect(
            MobileWorkspaceListEmptyState.state(
                workspaceCount: 4,
                visibleWorkspaceCount: 0,
                queryMatchedWorkspaceCount: 2,
                trimmedQuery: "release",
                filter: .unread
            ) == .filterNoMatches(.unread)
        )
    }

    @Test func activeFilterNoMatchesRendersFilterEmptyState() {
        #expect(
            MobileWorkspaceListEmptyState.state(
                workspaceCount: 4,
                visibleWorkspaceCount: 0,
                queryMatchedWorkspaceCount: 4,
                trimmedQuery: "",
                filter: .unread
            ) == .filterNoMatches(.unread)
        )
    }

    @Test func allFilterWithNoVisibleRowsHasNoSpecialState() {
        #expect(
            MobileWorkspaceListEmptyState.state(
                workspaceCount: 4,
                visibleWorkspaceCount: 0,
                queryMatchedWorkspaceCount: 4,
                trimmedQuery: "",
                filter: .all
            ) == nil
        )
    }
}

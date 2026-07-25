import Testing
@testable import CmuxMobileShellUI

@Suite struct MobilePrimarySearchCommitPolicyTests {
    @Test func activePresentedSearchAcceptsExplicitClear() {
        #expect(
            MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .active(.workspaces),
                isSearchPresented: true,
                scope: .workspaces,
                value: "",
                committedQuery: "Docs",
                suppressedEmptyCommitScope: nil
            )
        )
    }

    @Test func searchSubmitCleanupRejectsEmptyNativeWrite() {
        #expect(
            !MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .active(.workspaces),
                isSearchPresented: true,
                scope: .workspaces,
                value: "",
                committedQuery: "Docs",
                suppressedEmptyCommitScope: .workspaces
            )
        )
    }

    @Test func nonEmptyEditAfterSubmitStillCommits() {
        #expect(
            MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .active(.workspaces),
                isSearchPresented: true,
                scope: .workspaces,
                value: "Docs",
                committedQuery: "",
                suppressedEmptyCommitScope: .workspaces
            )
        )
    }

    @Test func deactivatingSearchRejectsPlatformCleanupWrite() {
        #expect(
            !MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .deactivating(.workspaces),
                isSearchPresented: true,
                scope: .workspaces,
                value: "",
                committedQuery: "Docs",
                suppressedEmptyCommitScope: nil
            )
        )
    }

    @Test func inactiveSearchRejectsLateNativeWrite() {
        #expect(
            !MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .inactive,
                isSearchPresented: false,
                scope: .workspaces,
                value: "",
                committedQuery: "Docs",
                suppressedEmptyCommitScope: nil
            )
        )
    }

    @Test func otherScopeRejectsNativeWrite() {
        #expect(
            !MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .active(.notifications),
                isSearchPresented: true,
                scope: .workspaces,
                value: "",
                committedQuery: "Docs",
                suppressedEmptyCommitScope: nil
            )
        )
    }
}

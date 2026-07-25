import Testing
@testable import CmuxMobileShellUI

@Suite struct MobilePrimarySearchCommitPolicyTests {
    @Test func activePresentedSearchAcceptsExplicitClear() {
        #expect(
            MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .active(.workspaces),
                isSearchPresented: true,
                scope: .workspaces
            )
        )
    }

    @Test func activePresentedSearchAcceptsNonEmptyEdit() {
        #expect(
            MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .active(.workspaces),
                isSearchPresented: true,
                scope: .workspaces
            )
        )
    }

    @Test func deactivatingSearchRejectsPlatformCleanupWrite() {
        #expect(
            !MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .deactivating(.workspaces),
                isSearchPresented: true,
                scope: .workspaces
            )
        )
    }

    @Test func inactiveSearchRejectsLateNativeWrite() {
        #expect(
            !MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .inactive,
                isSearchPresented: false,
                scope: .workspaces
            )
        )
    }

    @Test func otherScopeRejectsNativeWrite() {
        #expect(
            !MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
                searchPhase: .active(.notifications),
                isSearchPresented: true,
                scope: .workspaces
            )
        )
    }
}

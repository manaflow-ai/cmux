import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

/// First launch runs an unauthenticated auth sync that calls `signOut()`, and
/// signing out of an account calls it too. Neither may seed the
/// `PreviewMobileHost` fixtures ("cmux", "Docs") into the live store: those
/// fake rows rendered as real disconnected workspaces on first launch and
/// stayed after sign-in until the Mac connected. The list must be empty
/// instead; the fixtures are for SwiftUI previews and the UITest preview
/// harness only.
@MainActor
@Suite struct MobileSignOutPlaceholderWorkspaceTests {
    @Test func firstLaunchAuthSyncLeavesWorkspaceListEmpty() {
        let store = CMUXMobileShellStore(
            deliveredNotificationClearer: NoopDeliveredNotificationClearer()
        )

        store.signOut()

        #expect(store.workspaces.isEmpty)
        #expect(store.selectedWorkspaceID == nil)
        #expect(store.selectedTerminalID == nil)
    }

    @Test func signOutClearsWorkspacesWithoutSeedingPlaceholders() {
        let store = MobileShellComposite.preview()
        store.signIn()
        #expect(!store.workspaces.isEmpty)

        store.signOut()

        #expect(store.workspaces.isEmpty)
        #expect(store.selectedWorkspaceID == nil)
        #expect(store.selectedTerminalID == nil)
    }
}

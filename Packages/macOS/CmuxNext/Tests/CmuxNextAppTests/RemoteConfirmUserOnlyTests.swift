@testable import CmuxNextApp
import CmuxNextMacScreen
import Testing

/// "Share This Mac?" now has Always Allow, which turns on the user-only remote.shareWithoutAsking.
/// A debug.dialog press from an agent must not answer it, or it could give itself that setting.
@MainActor
@Suite struct RemoteConfirmUserOnlyTests {
    @Test func debugPressesCannotAnswerTheShareDialog() {
        #expect(DebugDialog.userOnly.contains(CmuxRemoteActionEnvironment.confirmIdentifier))
    }
}

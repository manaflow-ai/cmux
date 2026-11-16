@testable import CmuxNextApp
import CmuxNextMacScreen
import Testing

/// `remote.confirm`'s dialog (Share This Mac, a device's access, and sharing another Mac, whose Allow
/// signs an approval with this device's key) answers only to the person. An agent can send
/// `remote.confirm`; if the debug socket's `debug.dialog` could then press Allow (or Return), the
/// agent would approve its own request and get a signed, owner-attributed approval nobody clicked.
@MainActor
struct RemoteConfirmUserOnlyTests {
    @Test func theDebugSocketCannotAnswerTheRemoteConfirmDialog() {
        #expect(CmuxRemoteActionEnvironment.confirmIdentifier == "cmux.dialog.remote.confirm")
        #expect(DebugDialog.userOnly.contains(CmuxRemoteActionEnvironment.confirmIdentifier))
        #expect(CmuxRemoteActionEnvironment.setupIdentifiers.count == 5)
        #expect(CmuxRemoteActionEnvironment.setupIdentifiers.contains("cmux.dialog.screenSharing.setup.overview"))
        #expect(CmuxRemoteActionEnvironment.setupIdentifiers.isSubset(of: DebugDialog.userOnly))
    }
}

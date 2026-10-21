#if DEBUG
@testable import CmuxNextApp
import CmuxNextPhoneAccess
import Testing

/// `debug.dialog` never answers a dialog that admits someone: automation in a DEV build
/// must not press a phone's Allow.
@MainActor
struct DebugDialogUserOnlyTests {
    @Test func aPhonesAllowAnswersOnlyToThePerson() {
        #expect(DebugDialog.userOnly.contains(PhoneAdmission.allowDialogIdentifier))
    }
}
#endif

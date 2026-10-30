#if os(iOS)
import Testing
import UserNotifications
@testable import CmuxMobileShell

/// Notifications allowed in iOS Settings while cmux runs get a token when the app is next active.
@MainActor @Suite struct PushRegistrationTriggerTests {
    @Test func allowedPushBuildsRegister() {
        for status: UNAuthorizationStatus in [.authorized, .provisional, .ephemeral] {
            #expect(CmuxMobileAppDelegate.registersForPush(status: status, pushBuild: true))
        }
    }

    @Test func undecidedOrDeniedNotificationsDoNotRegister() {
        for status: UNAuthorizationStatus in [.notDetermined, .denied] {
            #expect(!CmuxMobileAppDelegate.registersForPush(status: status, pushBuild: true))
        }
    }

    @Test func aBuildWithoutPushNeverRegisters() {
        #expect(!CmuxMobileAppDelegate.registersForPush(status: .authorized, pushBuild: false))
    }
}
#endif

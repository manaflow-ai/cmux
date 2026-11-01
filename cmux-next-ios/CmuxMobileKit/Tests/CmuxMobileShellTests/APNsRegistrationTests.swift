import Foundation
import Testing
import UIKit
import UserNotifications
@testable import CmuxMobileShell

#if os(iOS)
/// Returning from iOS Settings after enabling notifications is another APNs
/// registration entrypoint; scene-based apps do not receive the app delegate's
/// applicationDidBecomeActive callback.
@MainActor @Suite struct APNsRegistrationTests {
    @Test func onlyPushBuildsWithGrantedSystemPermissionRegister() {
        let policy = APNsRegistrationDecision.self
        #expect(policy.shouldRegister(push: true, authorization: .authorized))
        #expect(policy.shouldRegister(push: true, authorization: .provisional))
        #expect(policy.shouldRegister(push: true, authorization: .ephemeral))
        #expect(!policy.shouldRegister(push: true, authorization: .notDetermined))
        #expect(!policy.shouldRegister(push: true, authorization: .denied))
        #expect(!policy.shouldRegister(push: false, authorization: .authorized))
    }

    @Test func returnFromSettingsRefreshesAuthorizationWithoutRelaunch() {
        let center = NotificationCenter()
        var checks = 0
        let watcher = APNsActivationObserver(center: center) { checks += 1 }
        watcher.start()
        // The launch check, with permission still off.
        #expect(checks == 1)

        // iOS Settings was opened, notifications were switched on, and the
        // same running application became active again.
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(checks == 2)

        // Register at most one observer, despite repeated startup calls.
        watcher.start()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(checks == 3)
        watcher.stop()
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(checks == 3)
    }
}
#endif

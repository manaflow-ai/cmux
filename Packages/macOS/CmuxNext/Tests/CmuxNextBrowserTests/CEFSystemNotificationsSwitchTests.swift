import Foundation
import Testing
@testable import CmuxNextBrowser

/// LAUNCH-NO-TCC-PROMPTS (Lawrence, 2026-10-30: "on launch, cmux will never ask for permissions"):
/// a first launch showed two macOS "Notifications may include alerts, sounds, and icon badges"
/// requests, one for the app and one for "cmux DEV Helper (Alerts)", with no banner posted by
/// cmux. Chromium creates its macOS notification bridge for the profile at startup when
/// `SystemNotifications` is on (notification_platform_bridge_delegator.cc,
/// `SystemNotificationsEnabled`), and that bridge's UNUserNotificationCenter service asks for
/// authorization for the app and its Alerts helper. `disable-notifications` only turns off web
/// notifications, so the browser process also starts with the feature off; DesktopNotifier keeps
/// the app's one request, made when cmux posts its first banner.
@Suite struct CEFSystemNotificationsSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func theBrowserProcessNeverStartsChromiumsSystemNotificationBridge(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("disable-features=SystemNotifications"))
        #expect(switches.arguments.contains("disable-notifications"))
    }
}

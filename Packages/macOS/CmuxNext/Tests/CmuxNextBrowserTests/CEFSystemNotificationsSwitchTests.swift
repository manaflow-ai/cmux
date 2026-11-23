import Foundation
import Testing
@testable import CmuxNextBrowser

/// LAUNCH-NO-TCC-PROMPTS (Lawrence, 2026-10-30: "on launch, cmux will never ask for permissions"):
/// a first launch showed two macOS "Notifications may include alerts, sounds, and icon badges"
/// requests, one for the app and one for "cmux DEV Helper (Alerts)", with no banner posted by
/// cmux. Chromium creates its macOS notification bridge for the profile at startup when
/// `SystemNotifications` is on (notification_platform_bridge_delegator.cc,
/// `SystemNotificationsEnabled`), and that bridge's UNUserNotificationCenter service asks for
/// authorization for the app and its Alerts helper. The browser process starts with the feature
/// off; DesktopNotifier keeps the app's one request, made when cmux posts its first banner.
@Suite struct CEFSystemNotificationsSwitchTests {
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func theBrowserProcessNeverStartsChromiumsSystemNotificationBridge(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: bundle, environment: [:])
        #expect(switches.arguments.contains("disable-features=SystemNotifications"))
    }

    /// GoDaddy reloaded forever in a Chromium tab (Lawrence, 2026-11-10): Akamai Bot Manager
    /// served its challenge page, the page saw no `Notification` and no `PushManager`, and Akamai
    /// asked again about twice per second, then denied the site. `disable-notifications` takes both
    /// interfaces out of every page, which no desktop Chrome does: Chrome with the two interfaces
    /// deleted loops the same way, and with them it passes after one reload. The switch must stay
    /// off the command line; a page then reads the permission as `default`, as in Chrome, and no
    /// notification is ever shown because nothing grants it.
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.tag"])
    func pagesKeepTheWebNotificationInterfacesChromeHas(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: bundle, environment: [:])
        #expect(!switches.arguments.contains("disable-notifications"))
    }

    /// 3319e649 passed `disable-features=BlockPromptsIfIgnoredOften` and `...IfDismissedOften` to
    /// stop Chromium blocking a site after a few unanswered permission prompts. Chromium has no
    /// feature of either name (components/permissions at 154 and the shipped 157 framework hold
    /// neither string): its count of ignored prompts has no switch at all
    /// (PermissionDecisionAutoBlocker::RecordIgnoreAndEmbargo). The two switches did nothing and
    /// said otherwise, so they must not be on the command line; the shim clears the site's count
    /// itself (shim_permissions.mm).
    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.tag"])
    func noSwitchNamesAnEmbargoFeatureChromiumDoesNotHave(bundle: String) {
        let switches = CEFSwitches.current(forkAPIVersion: 29, bundleIdentifier: bundle, environment: [:])
        #expect(!switches.arguments.contains { $0.contains("BlockPromptsIf") })
    }
}

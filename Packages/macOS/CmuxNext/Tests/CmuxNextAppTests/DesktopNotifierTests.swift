import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

@Suite struct DesktopNotifierTests {
    @Test func onlyMainAppBundleCanUseNotificationCenter() {
        #expect(DesktopNotifier.isMainAppBundle(
            bundleIdentifier: "com.cmuxterm.app.debug",
            bundleURL: URL(filePath: "/Applications/cmux DEV.app")
        ))
        #expect(DesktopNotifier.isMainAppBundle(
            bundleIdentifier: "com.cmuxterm.app",
            bundleURL: URL(filePath: "/Applications/cmux.app")
        ))
        #expect(!DesktopNotifier.isMainAppBundle(
            bundleIdentifier: "com.cmuxterm.app.debug.helper.alerts",
            bundleURL: URL(filePath: "/Applications/cmux DEV.app/Contents/Frameworks/cmux DEV Helper (Alerts).app")
        ))
        #expect(!DesktopNotifier.isMainAppBundle(
            bundleIdentifier: "com.cmuxterm.app.debug.helper",
            bundleURL: URL(filePath: "/Applications/cmux DEV.app/Contents/Frameworks/cmux DEV Helper.app")
        ))
    }

    @Test func malformedOrNonAppBundlesCannotRequestAuthorization() {
        #expect(!DesktopNotifier.isMainAppBundle(bundleIdentifier: nil, bundleURL: URL(filePath: "/tmp/cmux.app")))
        #expect(!DesktopNotifier.isMainAppBundle(
            bundleIdentifier: "com.cmuxterm.app.debug",
            bundleURL: URL(filePath: "/tmp/cmux")
        ))
        #expect(!DesktopNotifier.isMainAppBundle(
            bundleIdentifier: "org.chromium.cef.helper.alerts",
            bundleURL: URL(filePath: "/tmp/Alerts.app")
        ))
    }

    /// A terminal program writes its notification's title and text itself
    /// (OSC 9/777/99, an OSC 7501 record), so a program could pose as one in
    /// another terminal. Its banner names the workspace it came from (the
    /// program status spec: "Anything a terminal shows from a record SHOULD
    /// say which terminal it came from").
    @MainActor @Test func aTerminalProgramsBannerNamesItsWorkspace() {
        #expect(NotificationCenterService.bannerSubtitle(source: .terminal, workspace: "api server") == "api server")
        #expect(NotificationCenterService.bannerSubtitle(source: .agent, workspace: "api server") == nil)
        #expect(NotificationCenterService.bannerSubtitle(source: .cli, workspace: "api server") == nil)
        #expect(NotificationCenterService.bannerSubtitle(source: .terminal, workspace: nil) == nil)
        let notifier = DesktopNotifier()
        notifier.post(id: "n1", title: "terraform needs approval", subtitle: "api server", body: "Apply?",
                      surface: 7, workspace: "w1", defaultSound: false)
        #expect(notifier.posted.last?.subtitle == "api server")
        #expect(notifier.posted.last?.title == "terraform needs approval")
    }
}

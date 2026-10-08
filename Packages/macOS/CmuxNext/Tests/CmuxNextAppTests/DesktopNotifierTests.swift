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
}

import AppKit
@testable import CmuxNextApp
import Testing

/// First-run findings row 17: `git` on a Mac with no developer tools started macOS's "Install Command Line Developer
/// Tools", and its dialog opened behind the cmux window. A launch of that installer while cmux is active brings it
/// forward; a launch while the person works in another app, or of any other app, changes nothing. The launch is posted
/// as NSWorkspace posts it, on a center of the test's own.
@MainActor struct SystemInstallerFrontTests {
    private static func launch(_ app: NSRunningApplication, on center: NotificationCenter) {
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: NSWorkspace.shared,
                    userInfo: [NSWorkspace.applicationUserInfoKey: app])
    }

    /// The test host stands in for the installer: its own running app, read under a stand-in id (a `swift test` host
    /// may have no bundle id of its own).
    private static let host = NSRunningApplication.current
    private static let installer = "com.example.installer"
    private static func asInstaller(_ app: NSRunningApplication) -> String? { app == host ? installer : nil }

    @Test func theInstallerComesForwardWhileCmuxIsActive() {
        let center = NotificationCenter()
        var forward: [pid_t] = []
        let front = SystemInstallerFront(center: center, bundleIDs: [Self.installer], bundleID: Self.asInstaller,
                                         isActive: { true }) { forward.append($0.processIdentifier) }
        Self.launch(Self.host, on: center)
        #expect(forward == [Self.host.processIdentifier])
        withExtendedLifetime(front) {}
    }

    @Test func aLaunchWhileAnotherAppIsInFrontStaysWhereMacOSPutIt() {
        let center = NotificationCenter()
        var forward = 0
        let front = SystemInstallerFront(center: center, bundleIDs: [Self.installer], bundleID: Self.asInstaller,
                                         isActive: { false }) { _ in forward += 1 }
        Self.launch(Self.host, on: center)
        #expect(forward == 0)
        withExtendedLifetime(front) {}
    }

    @Test func anyOtherAppIsLeftAlone() {
        let center = NotificationCenter()
        var forward = 0
        let front = SystemInstallerFront(center: center, bundleID: Self.asInstaller, isActive: { true }) { _ in forward += 1 }
        Self.launch(Self.host, on: center)
        #expect(forward == 0)
        withExtendedLifetime(front) {}
    }

    @Test func theDefaultIsMacOSsDeveloperToolsInstaller() {
        #expect(SystemInstallerFront.installerBundleIDs == ["com.apple.dt.CommandLineTools.installondemand"])
    }
}

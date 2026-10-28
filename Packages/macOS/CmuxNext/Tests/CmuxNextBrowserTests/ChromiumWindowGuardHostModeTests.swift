import AppKit
@testable import CmuxNextBrowser
import os
import Testing

/// The guard against Chromium's own top-level windows is in-process machinery. The
/// runtime starts it only after an in-process boot; in host mode Chromium's windows are the host's, so
/// the guard that never started watches nothing and reports none (`debug.cef` `chromium_windows`).
@MainActor @Suite struct ChromiumWindowGuardHostModeTests {
    @Test func aGuardThatNeverStartedReportsNoWindow() {
        _ = NSApplication.shared
        let guardian = ChromiumWindowGuard(logger: Logger(subsystem: "com.cmuxterm.app.next.tests", category: "guard")) { _ in false }

        #expect(!guardian.isWatching)
        #expect(guardian.offendingWindows().isEmpty)
        #expect(guardian.blockedCount == 0)
    }

    @Test func aStartedGuardWatchesUntilStopped() {
        _ = NSApplication.shared
        let guardian = ChromiumWindowGuard(logger: Logger(subsystem: "com.cmuxterm.app.next.tests", category: "guard")) { _ in false }

        guardian.start()
        #expect(guardian.isWatching)
        guardian.stop()
        #expect(!guardian.isWatching)
    }
}

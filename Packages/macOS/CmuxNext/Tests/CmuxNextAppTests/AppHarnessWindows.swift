import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Testing

/// A test that builds the whole app (`AppServices`, its windows and their browser pages) closes
/// what that app opened when it ends: the shell windows, and the panels the app made for them
/// that nothing closes while the app runs (a page's Page Info and Extensions bubbles, which live
/// as long as the page's chrome). The app's services outlive the test, so those panels would
/// stay open in the test process for every suite after it.
@MainActor enum AppHarnessWindows {
    /// Closes every window the running test created that is still open.
    static func closeThoseThisTestOpened() {
        guard let test = Test.current else { return }
        let suite = WindowLeaks.suiteKey(of: test.id)
        let name = test.id.nameComponents.dropFirst().joined(separator: ".")
        for window in WindowLeaks.openWindows(ofSuite: suite) where WindowLeaks.owner(of: window)?.test == name {
            // Windows made in Swift are ARC's; close() must not release them on top of that.
            window.isReleasedWhenClosed = false
            window.close()
        }
    }

    /// `PinnedPageTests.withApp`, then the windows its app opened close: its pages are released
    /// as a tab close releases them (their chrome's bubbles go with them, including those of pages
    /// the daemon's events made outside the test's task), and what the test opened closes.
    static func withApp(_ body: (AppServices, DaemonConnection) async throws -> Void) async throws {
        var app: AppServices?
        defer {
            if let cache = app?.cache {
                for key in Array(cache.browsers.keys) { cache.release(key) }
            }
            closeThoseThisTestOpened()
        }
        try await PinnedPageTests.withApp { services, connection in
            app = services
            try await body(services, connection)
        }
    }
}

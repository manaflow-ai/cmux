import AppKit
import Foundation
import Testing
@testable import CmuxNextBrowser

/// A staged update's Chromium pre-warm (`--cmux-prewarm-chromium`, CMUX-571) starts Chromium for real in the new
/// copy, and must touch nothing of the person's: its root cache is its own folder in the temporary directory, the
/// keychain is the mock one, and nothing loads an extension or fetches in the background.
@Suite struct CEFStagedPrewarmTests {
    @Test func theRootCacheIsOneFolderPerBundleInTheTemporaryDirectory() {
        let temporary = URL(filePath: "/private/var/folders/xy/T", directoryHint: .isDirectory)
        let first = CEFStagedPrewarm.throwawayRoot(temporary: temporary, bundleIdentifier: "com.cmuxterm.app.nightly.next")
        #expect(first.deletingLastPathComponent().standardizedFileURL == temporary.standardizedFileURL)
        #expect(first.lastPathComponent == "cmux-prewarm-chromium-com.cmuxterm.app.nightly.next")
        #expect(first == CEFStagedPrewarm.throwawayRoot(temporary: temporary, bundleIdentifier: "com.cmuxterm.app.nightly.next"),
                "each pre-warm made a new folder: the temporary directory grows with every update")
        #expect(first != CEFStagedPrewarm.throwawayRoot(temporary: temporary, bundleIdentifier: "com.cmuxterm.app.next"))
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "/nonexistent"
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? "/nonexistent"
        let real = CEFStagedPrewarm.throwawayRoot(bundleIdentifier: "com.cmuxterm.app.next").path
        #expect(!real.hasPrefix(support) && !real.hasPrefix(caches), "\(real) is under the app's own data")
    }

    @Test func switchesAreTheAppsWithTheMockKeychainAndNoExtensionsOrBackgroundFetches() {
        let switches = CEFStagedPrewarm.switches(forkAPIVersion: 7, rendererPaths: false, bundleIdentifier: "com.cmuxterm.app.next")
        #expect(switches.contains("use-mock-keychain"), "a release bundle read the real Chromium Safe Storage key")
        #expect(switches.contains("disable-background-networking"))
        #expect(switches.contains("disable-component-update"))
        #expect(!switches.contains { $0.hasPrefix("load-extension=") })
        #expect(!switches.contains { $0.hasPrefix("profile-directory=") })
        let app = CEFSwitches.current(forkAPIVersion: 7, bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
        #expect(app.allSatisfy { switches.contains($0) }, "the pre-warm left out an app switch: the first launch starts a different Chromium")
    }

    @Test func outcomesAreDistinctExitStatusesWithALoadAsSuccess() {
        let all: [CEFStagedPrewarm.Outcome] = [.loaded, .notEmbedded, .loadFailed, .application, .initializeFailed, .browserRefused, .timedOut]
        #expect(CEFStagedPrewarm.Outcome.loaded.rawValue == 0)
        #expect(Set(all.map(\.rawValue)).count == all.count)
    }

    /// CefShutdown under a Chromium window that is still alive read freed memory on the main thread ("cmux exit 11" in
    /// Leo's NIGHTLY update log, 2026-11-16): the pre-warm shuts down in the app's quit order, never on the browser
    /// count alone.
    @Test func shutdownWaitsForEveryWindowNotOnlyEveryBrowser() {
        #expect(!CEFStagedPrewarm.readyToShutDown(liveBrowsers: 0, windows: 1, pendingCreates: 0), "CefShutdown ran with the page's window alive")
        #expect(!CEFStagedPrewarm.readyToShutDown(liveBrowsers: 1, windows: 0, pendingCreates: 0))
        #expect(CEFStagedPrewarm.readyToShutDown(liveBrowsers: 0, windows: 0, pendingCreates: 0))
        #expect(CEFStagedPrewarm.readyToShutDown(liveBrowsers: 0, windows: -1, pendingCreates: 0), "stock CEF has no window count: that wait is skipped")
    }

    /// The page's create is asynchronous: from the create call until OnAfterCreated, both the browser and the window
    /// count read 0, and a CefShutdown then runs under the creation (the same crash). Held back here: the session's
    /// create stays pending, so the pre-warm does not shut down, until the shim's OnAfterCreated event arrives.
    @MainActor @Test func shutdownWaitsForAPendingCreateUntilOnAfterCreated() {
        let session = CEFPrewarmSession()
        func ready() -> Bool { CEFStagedPrewarm.readyToShutDown(liveBrowsers: 0, windows: 0, pendingCreates: session.pendingCreates) }
        session.createStarted()
        #expect(!ready(), "CefShutdown would run while the page was still being made")
        let context = Unmanaged.passUnretained(session).toOpaque()
        CEFPrewarmSession.event(context, 9, 1, 0, 0, 0, nil, nil)  // CMUX_SHIM_LOAD_END: no create ends with it
        #expect(session.loaded)
        #expect(!ready())
        CEFPrewarmSession.event(context, 2, 1, 0, 0, 0, nil, nil)  // CMUX_SHIM_AFTER_CREATED
        #expect(ready())
        session.createStarted()
        session.createEnded()  // a refused create call
        #expect(ready())
        withExtendedLifetime(session) {}
    }

    @MainActor @Test func aBundleWithNoRuntimeEndsBeforeChromium() {
        #expect(CEFStagedPrewarm().run(application: NSApplication.shared, layout: nil) == .notEmbedded)
    }
}

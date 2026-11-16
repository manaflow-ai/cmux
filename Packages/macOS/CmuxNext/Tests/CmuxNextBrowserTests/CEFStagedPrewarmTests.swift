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

    @MainActor @Test func aBundleWithNoRuntimeEndsBeforeChromium() {
        #expect(CEFStagedPrewarm().run(application: NSApplication.shared, layout: nil) == .notEmbedded)
    }
}

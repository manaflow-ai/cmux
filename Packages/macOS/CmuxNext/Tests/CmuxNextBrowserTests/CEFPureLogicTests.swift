import Foundation
import Testing
@testable import CmuxNextBrowser

@Suite struct CEFSwitchesTests {
    @Test func forkBuildGetsTabbedWindowsAndNoFieldTrials() {
        let switches = CEFSwitches(forkAPIVersion: 2, useMockKeychain: false, loadExtensions: [])
        #expect(switches.arguments == [
            "cmux-tabbed-windows", "disable-field-trial-config", "disable-notifications",
            "disable-features=MacAppCodeSignClone",
        ])
    }

    /// Chromium's code-sign clone makes CefShutdown spawn a
    /// `--type=code-sign-clone-cleanup` helper that outlives the app (cx-dj33).
    @Test func everyBundleDisablesTheCodeSignClone() {
        for bundle in ["com.cmuxterm.app", "com.cmuxterm.app.debug.x"] {
            let switches = CEFSwitches.current(forkAPIVersion: 2, bundleIdentifier: bundle, environment: [:])
            #expect(switches.arguments.contains("disable-features=MacAppCodeSignClone"))
        }
        #expect(CEFSwitches(forkAPIVersion: 0, useMockKeychain: false, loadExtensions: [])
            .arguments.contains("disable-features=MacAppCodeSignClone"))
    }

    @Test func stockCEFHasNoTabbedWindows() {
        let switches = CEFSwitches(forkAPIVersion: 0, useMockKeychain: false, loadExtensions: [])
        #expect(!switches.arguments.contains("cmux-tabbed-windows"))
    }

    @Test func devBundleUsesMockKeychainAndExtensionsList() {
        let switches = CEFSwitches.current(
            forkAPIVersion: 2,
            bundleIdentifier: "com.cmuxterm.app.debug.cefnx",
            environment: ["CMUX_NEXT_CEF_LOAD_EXTENSIONS": "/tmp/a::/tmp/b"]
        )
        #expect(switches.useMockKeychain)
        #expect(switches.loadExtensions == ["/tmp/a", "/tmp/b"])
        #expect(switches.arguments.contains("load-extension=/tmp/a,/tmp/b"))
        // The shim merges disable-features into CEF's own list (GlicActorUi,
        // ...; CEFShim/src/command_line_switches.h); replacing that list
        // crashes in ActorUiContentsContainerController. cmux adds one entry.
        #expect(switches.arguments.filter { $0.hasPrefix("disable-features") } == ["disable-features=MacAppCodeSignClone"])
    }

    @Test func releaseBundleUsesRealKeychain() {
        let switches = CEFSwitches.current(forkAPIVersion: 2, bundleIdentifier: "com.cmuxterm.app", environment: [:])
        #expect(!switches.useMockKeychain)
        #expect(switches.loadExtensions.isEmpty)
    }

    @Test func extraSwitchesOnlyForDevelopmentBundles() {
        let environment = ["CMUX_NEXT_CEF_EXTRA_SWITCHES": "--enable-ui-devtools=9311::show-browser-frame-regions"]
        #expect(CEFSwitches.extraSwitches("--enable-ui-devtools=9311::show-browser-frame-regions")
            == ["enable-ui-devtools=9311", "show-browser-frame-regions"])
        #if DEBUG
        let dev = CEFSwitches.current(forkAPIVersion: 2, bundleIdentifier: "com.cmuxterm.app.debug.x", environment: environment)
        #expect(dev.arguments.suffix(2) == ["enable-ui-devtools=9311", "show-browser-frame-regions"])
        #endif
        let release = CEFSwitches.current(forkAPIVersion: 2, bundleIdentifier: "com.cmuxterm.app", environment: environment)
        #expect(release.extraSwitches.isEmpty)
    }
}

@Suite struct CEFLibraryLoadTests {
    @Test func loadWithoutRuntimeFailsOffMain() async {
        let result = await Task.detached { CEFRuntime.loadLibrary(nil) }.value
        guard case .failure(.notEmbedded) = result else {
            Issue.record("expected notEmbedded, got \(result)")
            return
        }
    }

    @Test func loadWithMissingShimReportsShimError() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "cef-missing-\(UUID().uuidString)")
        let layout = CEFRuntimeLayout(
            frameworksDirectory: root, mainBundle: root, helperApp: root.appending(path: "Helper.app")
        )
        let result = await Task.detached { CEFRuntime.loadLibrary(layout) }.value
        guard case .failure(.shim(.open)) = result else {
            Issue.record("expected a shim open error, got \(result)")
            return
        }
    }
}

@Suite struct CEFZoomTests {
    @Test func zoomLevelRoundTrips() {
        #expect(CEFZoom.level(forFactor: 1) == 0)
        #expect(abs(CEFZoom.level(forFactor: 1.2) - 1) < 1e-9)
        #expect(abs(CEFZoom.factor(forLevel: CEFZoom.level(forFactor: 1.5)) - 1.5) < 1e-9)
        #expect(CEFZoom.level(forFactor: 0) == 0)
    }
}

@Suite struct CEFShimEventTests {
    private func event(_ kind: Int32, browser: Int32 = 7, request: Int32 = 0, a: Int64 = 0, b: Int64 = 0,
                       s1: String = "", s2: String = "") -> CEFShimEvent {
        CEFShimEvent(kind: kind, browser: browser, request: request, a: a, b: b, s1: s1, s2: s2)
    }

    @Test func decodesLifetimeEvents() {
        #expect(event(1) == .contextInitialized)
        #expect(event(2, request: 4, a: 99) == .afterCreated(browser: 7, request: 4, window: 99))
        #expect(event(3) == .beforeClose(browser: 7))
    }

    @Test func decodesLoadingStateBits() {
        #expect(event(7, a: 0b101) == .loadingState(browser: 7, loading: true, canGoBack: false, canGoForward: true))
        #expect(event(7, a: 0b010) == .loadingState(browser: 7, loading: false, canGoBack: true, canGoForward: false))
    }

    @Test func decodesProgressAndFind() {
        #expect(event(11, a: 450) == .progress(browser: 7, value: 0.45))
        #expect(event(11, a: 5000) == .progress(browser: 7, value: 1))
        let packed = Int64(3) | (Int64(1) << 32)
        #expect(event(14, a: 9, b: packed) == .findResult(browser: 7, count: 9, activeOrdinal: 3, isFinal: true))
        #expect(event(14, a: 9, b: 3) == .findResult(browser: 7, count: 9, activeOrdinal: 3, isFinal: false))
    }

    @Test func decodesForkTabEvents() {
        #expect(event(16, browser: 0, request: 6, a: 11, b: 0) == .tab(.windowDestroyed, browser: 0, window: 11, value: 0))
        #expect(event(16, request: 42) == .tab(.unknown, browser: 7, window: 0, value: 0))
        #expect(event(99) == .unknown(kind: 99))
    }

    @Test func eventsCarryTheirBrowser() {
        #expect(event(5, s1: "t").browserID == 7)
        #expect(event(1).browserID == nil)
    }
}

@Suite struct CEFShutdownSequenceTests {
    @Test func waitsForBrowsersThenWindows() {
        var sequence = CEFShutdownSequence(liveBrowsers: 2, windows: 1)
        sequence.begin()
        #expect(sequence.phase == .closingBrowsers)
        sequence.browserClosed(remaining: 1)
        #expect(sequence.phase == .closingBrowsers)
        sequence.browserClosed(remaining: 0)
        #expect(sequence.phase == .waitingForWindows)
        sequence.windowDestroyed(remaining: 0)
        #expect(sequence.phase == .readyToShutdown)
    }

    @Test func windowDestroyedBeforeLastCloseStillWaitsForBrowsers() {
        var sequence = CEFShutdownSequence(liveBrowsers: 1, windows: 1)
        sequence.begin()
        sequence.windowDestroyed(remaining: 0)
        #expect(sequence.phase == .closingBrowsers)
        sequence.browserClosed(remaining: 0)
        #expect(sequence.phase == .readyToShutdown)
    }

    @Test func nothingLiveIsReadyAtOnce() {
        var sequence = CEFShutdownSequence(liveBrowsers: 0, windows: 0)
        sequence.begin()
        #expect(sequence.phase == .readyToShutdown)
    }

    @Test func stockCEFSkipsTheWindowWait() {
        var sequence = CEFShutdownSequence(liveBrowsers: 1, windows: -1)
        sequence.begin()
        sequence.browserClosed(remaining: 0)
        #expect(sequence.phase == .readyToShutdown)
    }
}

/// Imported passwords are never stored under Chromium's mock Keychain key
/// (a public constant): development bundles cannot import them.
@MainActor @Suite struct PasswordImportKeyTests {
    @Test func mockKeychainBuildsRefusePasswordImport() {
        #expect(PasswordImportKey.storesUnderMockKey(bundleIdentifier: "com.cmuxterm.app.debug.tag", environment: [:]))
        #expect(PasswordImportKey.storesUnderMockKey(bundleIdentifier: "com.cmuxterm.app", environment: ["CMUX_MOCK_KEYCHAIN": "1"]))
        #expect(!PasswordImportKey.storesUnderMockKey(bundleIdentifier: "com.cmuxterm.app", environment: [:]))
        #if DEBUG
        #expect(!PasswordImportKey.storesUnderMockKey(bundleIdentifier: "com.cmuxterm.app.debug.tag",
                                               environment: ["CMUX_NEXT_PASSWORD_IMPORT_MOCK_KEY": "throwaway"]),
                "throwaway test data only")
        #endif
    }
}

/// The caller's passwords are zeroed once, as soon as the shim has copied the rows.
@Suite struct PasswordRowsCopyTests {
    @Test func copiedRunsTheZeroingOnce() {
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let secret: [UInt8] = Array("hunter2".utf8)
        secret.withUnsafeBytes { bytes in
            let rows = ChromiumPasswordRows([(url: "https://example.com/", signonRealm: "https://example.com/", username: "u", password: bytes, created: nil)],
                                            afterCopy: { count.value += 1 })
            rows.copied()
            rows.copied()
        }
        #expect(count.value == 1)
    }
}

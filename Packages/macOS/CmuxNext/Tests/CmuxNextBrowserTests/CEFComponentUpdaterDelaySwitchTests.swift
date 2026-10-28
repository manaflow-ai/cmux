@testable import CmuxNextBrowser
import Foundation
import Testing

/// Chromium's component updater starts its first check 5 minutes after Chromium starts, not 1 (first-seconds
/// bench, 2026-10-28). With in-process Chromium the app's main thread is Chromium's UI thread, and the first check
/// downloaded 60-100 MB of components (WasmTtsEngine, WidevineCdm, OnDeviceHeadSuggest, ...) in the first minutes of
/// a launch: the CEF pump woke the main thread 14-26 times a second from +60 s to +120 s
/// (`update_client::UrlFetcherDownloader` -> `SimpleURLLoader` reads on the UI thread). The components stay
/// (perf-lead.md "Chrome runtime idle services"); the check runs later, as background work the person never sees.
@Suite struct CEFComponentUpdaterDelaySwitchTests {
    private static let prefix = "component-updater="

    private static func arguments(bundle: String) -> [String] {
        CEFSwitches.current(forkAPIVersion: CEFSwitches.resizeSyncForkAPI, bundleIdentifier: bundle, environment: [:]).arguments
    }

    @Test(arguments: ["com.cmuxterm.app.next", "com.cmuxterm.app.debug.tag"])
    func theFirstComponentCheckWaitsFiveMinutes(bundle: String) {
        let entries = Self.arguments(bundle: bundle).filter { $0.hasPrefix(Self.prefix) }
        // One entry: Chromium reads the last value of a switch given twice. A Debug CMUX_NEXT_CEF_EXTRA_SWITCHES
        // value comes later and replaces it (devtools-device-mode-live.py passes `fast-update`).
        #expect(entries == ["component-updater=initial-delay=300"], "\(entries)")
    }

    @Test func theComponentUpdaterStaysOn() {
        let arguments = Self.arguments(bundle: "com.cmuxterm.app.next")
        #expect(!arguments.contains("disable-component-update"))
        #expect(!arguments.contains { $0.hasPrefix(Self.prefix) && $0.contains("disable-background-downloads") })
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The Chromium Host starts Chromium with the same switch set.
    @Test func theChromiumHostGetsTheSameDelay() {
        let root = URL(filePath: "/nonexistent/cmux-component-delay")
        let layout = CEFRuntimeLayout(frameworksDirectory: root, mainBundle: root, helperApp: root)
        let host = ChromiumHostConfiguration.arguments(layout: layout, rootCache: root, bundleIdentifier: "com.cmuxterm.app.next",
                                                       environment: [:])
        #expect(host.contains("--cef-switch=component-updater=initial-delay=300"))
    }
    #endif
}

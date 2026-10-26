#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing
import CmuxNextWakeups

/// The out-of-process Chromium host stays off until a developer turns it on: Chromium tabs run in
/// process (Japanese IME, find, drag and permission prompts do not work in the host yet).
@MainActor
@Suite struct ChromiumHostDefaultOffTests {
    /// Debug Settings as the app holds them, with nothing changed.
    private static func defaults() -> TunableStore {
        let store = TunableStore()
        store.register(BrowserHostTunables.all)
        store.activate(file: nil)
        return store
    }

    @Test func theHostIsOffByDefault() {
        #expect(BrowserHostTunables.helper.defaultValue == false)
        #expect(BrowserHostTunables.helper.value(in: Self.defaults()) == false)
    }

    /// Off keeps Chromium in process; on picks the host backend (task 015).
    @Test func theBackendFollowsTheToggle() {
        let store = Self.defaults()
        #expect(BrowserHostTunables.backend(in: store) == .inProcess)
        store.set(BrowserHostTunables.helper.key, .bool(true))
        #expect(BrowserHostTunables.backend(in: store) == .host)
    }

    @Test func withDefaultSettingsNoHostStarts() {
        var asked = 0
        let prototype = ChromiumHostPrototype(makeConfiguration: {
            asked += 1
            return ChromiumHostConfiguration(executable: URL(filePath: "/bin/true"), arguments: [])
        }, tunables: Self.defaults(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let reply = prototype.open("https://example.com/", over: NSView(frame: .zero), focus: false)
        #expect(reply["error"] as? String == "browserHost.helper is off")
        #expect(asked == 0)
        #expect(prototype.report["phase"] as? String == "none")
    }

    /// The toggle a bench run's override file turns on (chromium-host-bench.py; a bench build
    /// registers it, BrowserHostTunables.all) lets `open` past the gate: here it stops at the
    /// pane check, before any host starts.
    @Test func withTheToggleOnOpenGetsPastTheGate() {
        let store = Self.defaults()
        store.load(raw: TunableFile.decode(Data(#"{"version": 1, "values": {"browserHost.helper": true}}"#.utf8)))
        let prototype = ChromiumHostPrototype(makeConfiguration: { nil }, tunables: store, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let reply = prototype.open("https://example.com/", over: NSView(frame: .zero), focus: false)
        #expect(reply["error"] as? String == "the pane is not in a window")
        #expect(prototype.report["tunable"] as? Bool == true)
    }
}
#endif

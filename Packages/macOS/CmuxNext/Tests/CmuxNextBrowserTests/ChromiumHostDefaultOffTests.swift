#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing
import CmuxNextWakeups

/// The out-of-process Chromium host stays off until a developer turns it on: Chromium tabs run in
/// process (Japanese IME, find, drag and permission prompts do not work in the host yet). The
/// switch is the feature `cefHelperHost` (ChromiumHostSwitchTests in CmuxNextAppTests); its
/// Debug Settings override `browserHost.helper` is unset by default.
@MainActor
@Suite struct ChromiumHostDefaultOffTests {
    @Test func theOverrideIsUnsetByDefault() {
        let store = TunableStore()
        store.register(BrowserHostTunables.all)
        store.activate(file: nil)
        #expect(BrowserHostTunables.helper.defaultValue == false)
        #expect(store.override(BrowserHostTunables.helper.key) == nil)
    }

    /// Off keeps Chromium in process; on picks the host backend in Debug builds (task 015), and a
    /// bench build never moves a tab to it.
    @Test func theBackendFollowsTheSwitch() {
        #expect(BrowserHostTunables.backend(hostEnabled: false) == .inProcess)
        #if DEBUG
        #expect(BrowserHostTunables.backend(hostEnabled: true) == .host)
        #else
        #expect(BrowserHostTunables.backend(hostEnabled: true) == .inProcess)
        #endif
    }

    @Test func withTheSwitchOffNoHostStarts() {
        var asked = 0
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let prototype = ChromiumHostPrototype(makeConfiguration: {
            asked += 1
            return ChromiumHostConfiguration(executable: URL(filePath: "/bin/true"), arguments: [])
        }, isOn: { false }, mainWork: work, deadlines: MainDeadlineScheduler(work: work))
        let reply = prototype.open("https://example.com/", over: NSView(frame: .zero), focus: false)
        #expect(reply["error"] as? String == "cefHelperHost is off")
        #expect(asked == 0)
        #expect(prototype.report["phase"] as? String == "none")
        #expect(prototype.report["enabled"] as? Bool == false)
    }

    /// The switch on (`CMUX_ENABLE_FEATURES=cefHelperHost`, or a bench run's override file,
    /// chromium-host-bench.py) lets `open` past the gate: here it stops at the pane check, before
    /// any host starts. The switch is read at `open`, not at init.
    @Test func withTheSwitchOnOpenGetsPastTheGate() {
        var on = false
        let work = MainWorkScheduler(budget: MainFrameBudget())
        let prototype = ChromiumHostPrototype(makeConfiguration: { nil }, isOn: { on }, mainWork: work,
                                              deadlines: MainDeadlineScheduler(work: work))
        on = true
        let reply = prototype.open("https://example.com/", over: NSView(frame: .zero), focus: false)
        #expect(reply["error"] as? String == "the pane is not in a window")
        #expect(prototype.report["enabled"] as? Bool == true)
    }
}
#endif

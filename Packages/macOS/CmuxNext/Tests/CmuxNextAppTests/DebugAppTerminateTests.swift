import AppKit
import CmuxNextDaemonService
import CmuxNextWakeups
import Testing

#if DEBUG || CMUX_BENCH_HOOKS
/// REOPEN VIDEO's logout case (cmux-ad 2026-11-02 01:30Z): `debug.app.terminate {reason: "logout"}` quits the way a
/// logout does (the power-off notice every observer of the workspace center sees, then terminate), so the quit is
/// `.powerOff` and never asks; any other reason quits nothing. (Port of #31645 to the dogfood line: the tracker
/// observes through the app's `AppEvents` fan-out here.)
@MainActor
struct DebugAppTerminateTests {
    @Test func aLogoutQuitIsPowerOffAndTerminatesOnce() {
        let center = NotificationCenter()
        let origins = QuitOriginTracker(workspaceEvents: AppEvents(center: center))
        var terminations = 0
        let refusal = origins.debugTerminate(reason: "logout", center: center) { terminations += 1 }
        #expect(refusal == nil, "debug.app.terminate refused a logout: \(refusal ?? "")")
        #expect(terminations == 1, "a logout must start one termination, not \(terminations)")
        #expect(origins.consume() == .powerOff, "after a logout the quit must be power-off (it never asks)")
    }

    @Test func anotherReasonQuitsNothing() {
        let center = NotificationCenter()
        let origins = QuitOriginTracker(workspaceEvents: AppEvents(center: center))
        var terminations = 0
        let refusal = origins.debugTerminate(reason: "whatever", center: center) { terminations += 1 }
        #expect(refusal != nil, "an unknown reason must be refused")
        #expect(terminations == 0)
        #expect(origins.consume() == .interactive, "a refused reason must not mark the next quit power-off")
    }
}
#endif

import AppKit
import CmuxNextDaemonService
import Testing

#if DEBUG || CMUX_BENCH_HOOKS
/// REOPEN VIDEO's logout case (cmux-ad 2026-11-02 01:30Z): `debug.app.terminate {reason: "logout"}` quits the way a
/// logout does (the power-off notice every observer sees, then terminate), so the quit is `.powerOff` and never
/// asks; any other reason quits nothing.
@MainActor
struct DebugAppTerminateTests {
    @Test func aLogoutQuitIsPowerOffAndTerminatesOnce() {
        let origins = QuitOriginTracker(center: NotificationCenter())
        var terminations = 0
        let refusal = origins.debugTerminate(reason: "logout") { terminations += 1 }
        #expect(refusal == nil, "debug.app.terminate refused a logout: \(refusal ?? "")")
        #expect(terminations == 1, "a logout must start one termination, not \(terminations)")
        #expect(origins.consume() == .powerOff, "after a logout the quit must be power-off (it never asks)")
    }

    @Test func anotherReasonQuitsNothing() {
        let origins = QuitOriginTracker(center: NotificationCenter())
        var terminations = 0
        let refusal = origins.debugTerminate(reason: "whatever") { terminations += 1 }
        #expect(refusal != nil, "an unknown reason must be refused")
        #expect(terminations == 0)
        #expect(origins.consume() == .interactive, "a refused reason must not mark the next quit power-off")
    }
}
#endif

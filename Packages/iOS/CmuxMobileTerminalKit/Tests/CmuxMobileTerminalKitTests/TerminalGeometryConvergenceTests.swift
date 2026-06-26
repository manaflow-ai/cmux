import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalGeometryConvergence present-discard convergence")
struct TerminalGeometryConvergenceTests {
    private let window = TerminalGeometryConvergence.window
    private let hold = TerminalGeometryConvergence.minimumHold

    @Test("idle and not armed before any geometry change")
    func idleWhenUnarmed() {
        var converge = TerminalGeometryConvergence()
        #expect(converge.isArmed == false)
        #expect(converge.tick(now: 100, presented: false) == .idle)
        #expect(converge.tick(now: 100, presented: true) == .idle)
    }

    @Test("arming starts a redraw window")
    func armStartsWindow() {
        var converge = TerminalGeometryConvergence()
        converge.arm(now: 100)
        #expect(converge.isArmed == true)
        #expect(converge.tick(now: 100, presented: false) == .redraw)
    }

    @Test("holds the redraw before the minimum hold even once a frame presents")
    func holdsBeforeMinimumHold() {
        var converge = TerminalGeometryConvergence()
        converge.arm(now: 100)
        // A frame matching the current size right after a resize can be a
        // transient mid-animation match; do not disarm on it before the hold.
        #expect(converge.tick(now: 100 + hold / 2, presented: true) == .redraw)
        #expect(converge.isArmed == true)
    }

    // The crux of the fix: once the minimum hold has elapsed but NO frame has
    // presented at the current size, the loop must KEEP converging up to the
    // deadline instead of giving up. The pre-fix blind burst returned `.settled`
    // here, leaving the terminal blank / typed text invisible.
    @Test("keeps converging past the hold while no frame has presented")
    func keepsConvergingUntilPresented() {
        var converge = TerminalGeometryConvergence()
        converge.arm(now: 100)
        #expect(converge.tick(now: 100 + hold + 0.05, presented: false) == .redraw)
        #expect(converge.tick(now: 100 + hold + 0.2, presented: false) == .redraw)
        #expect(converge.isArmed == true)
    }

    @Test("settles and disarms once a frame presents after the hold")
    func settlesAfterPresented() {
        var converge = TerminalGeometryConvergence()
        converge.arm(now: 100)
        #expect(converge.tick(now: 100 + hold + 0.05, presented: true) == .settled)
        #expect(converge.isArmed == false)
        // After settling there is nothing more to drive.
        #expect(converge.tick(now: 100 + hold + 0.1, presented: false) == .idle)
    }

    // The deadline is the safety bound: a layer that never presents at a
    // matching size must stop pumping the main queue rather than redraw forever.
    @Test("times out and disarms at the deadline when never presented")
    func timesOutAtDeadline() {
        var converge = TerminalGeometryConvergence()
        converge.arm(now: 100)
        #expect(converge.tick(now: 100 + window - 0.01, presented: false) == .redraw)
        #expect(converge.tick(now: 100 + window, presented: false) == .timedOut)
        #expect(converge.isArmed == false)
        #expect(converge.tick(now: 100 + window + 1, presented: false) == .idle)
    }

    @Test("disarm cancels an active window")
    func disarmCancels() {
        var converge = TerminalGeometryConvergence()
        converge.arm(now: 100)
        converge.disarm()
        #expect(converge.isArmed == false)
        #expect(converge.tick(now: 100.1, presented: false) == .idle)
    }

    @Test("re-arming extends the window from the new geometry change")
    func reArmExtendsWindow() {
        var converge = TerminalGeometryConvergence()
        converge.arm(now: 100)
        // A second geometry change (e.g. the next keyboard-animation step)
        // re-arms, so the hold/deadline are measured from the latest change.
        converge.arm(now: 100 + hold)
        // Now `100 + hold + 0.05` is only 0.05s past the *new* arm — still well
        // within the hold, so it keeps converging.
        #expect(converge.tick(now: 100 + hold + 0.05, presented: true) == .redraw)
        // ...and it still settles correctly once the new hold has elapsed.
        #expect(converge.tick(now: 100 + 2 * hold + 0.05, presented: true) == .settled)
    }
}

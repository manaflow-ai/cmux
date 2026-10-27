import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The CEF pump runs on the main thread, so it is a phase of the main thread's episode, not a
/// hang-watch scope (p10-stability-031): each pass runs with the crash keys' CEF state at `inPump`, which
/// the main-thread watchdog reads while the main thread is suspended and names `cef_pump` in its records.
@MainActor
@Suite struct CEFMessagePumpCrashKeyTests {
    /// The pump's timer, fired by hand.
    final class Timer: CEFPumpTimer {
        var onFire: (() -> Void)?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) {}
        func disarm() {}
        func invalidate() {}
        func fire() { onFire?() }
    }

    private static let inPump = CrashKeySlots.CEFState.inPump.rawValue
    private static let running = CrashKeySlots.CEFState.running.rawValue

    @Test func aPassRunsInThePumpStateAndPutsTheStateBefore() {
        let keys = CrashKeySlots()
        keys.set(.cefState, Self.running)
        var during: [UInt64] = []
        let timer = Timer()
        let pump = CEFMessagePump(work: { during.append(keys.value(.cefState)) }, timer: timer,
                                  clock: { 100 }, ledger: WakeupLedger(), crashKeys: keys)
        pump.start()
        timer.fire()
        #expect(during == [Self.inPump], "in the pump while CefDoMessageLoopWork runs")
        #expect(keys.value(.cefState) == Self.running, "the state before the pass once it returns")
        pump.stop()
    }

    /// A menu or modal panel that CefDoMessageLoopWork opens runs a nested run loop inside the pass: the
    /// main thread does AppKit's work there, not Chromium's, so the pump's fire in that loop puts the state
    /// before the pass back; a stall in the menu is not named `cef_pump`.
    @Test func aNestedRunLoopInsideAPassLeavesThePumpState() {
        let keys = CrashKeySlots()
        keys.set(.cefState, Self.running)
        var seen: [UInt64] = []
        var nested = false
        let timer = Timer()
        let pump = CEFMessagePump(work: {
            seen.append(keys.value(.cefState))
            guard !nested else { return }
            nested = true
            timer.fire() // the nested run loop fires the pump's timer: a reentrant fire runs no work
            seen.append(keys.value(.cefState))
        }, timer: timer, clock: { 100 }, ledger: WakeupLedger(), crashKeys: keys)
        pump.start()
        timer.fire()
        #expect(seen == [Self.inPump, Self.running], "in the pump, then not once the nested loop fired it")
        #expect(pump.stats.reentrantFires == 1)
        #expect(keys.value(.cefState) == Self.running)
        pump.stop()
    }

    @Test func aPumpWithNoCrashKeysStillRunsItsPasses() {
        var passes = 0
        let timer = Timer()
        let pump = CEFMessagePump(work: { passes += 1 }, timer: timer, clock: { 100 },
                                  ledger: WakeupLedger(), crashKeys: nil)
        pump.start()
        timer.fire()
        #expect(passes == 1)
        pump.stop()
    }
}

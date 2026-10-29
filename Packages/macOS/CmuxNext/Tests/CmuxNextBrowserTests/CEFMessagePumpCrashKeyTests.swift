import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The CEF pump runs on the main thread, so it is a phase of the main thread's episode, not a
/// hang-watch scope: each pass runs with the crash keys' CEF state at `inPump`, which
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
                                  clock: { 100 }, ledger: WakeupLedger(), crashKeys: keys, trace: TraceRuntime(role: .app))
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
        }, timer: timer, clock: { 100 }, ledger: WakeupLedger(), crashKeys: keys, trace: TraceRuntime(role: .app))
        pump.start()
        timer.fire()
        #expect(seen == [Self.inPump, Self.running], "in the pump, then not once the nested loop fired it")
        #expect(pump.stats.reentrantFires == 1)
        #expect(keys.value(.cefState) == Self.running)
        pump.stop()
    }

    /// The Chromium host has no app crash keys: the pump still sets the trace runtime's `in_cef_pump` for the
    /// pass and puts the value it found back after (Chrome's `ScopedCrashKeyString`).
    @Test func aPassSetsInCEFPumpAndPutsTheValueBefore() {
        let trace = Self.pumpTrace()
        withKnownIssue("078 crash-key page: a runtime with no page keeps no key") {
            trace.setCrashKey(.inCEFPump, 9) // a value an outer scope set
            var during: [UInt64] = []
            let timer = Timer()
            let pump = CEFMessagePump(work: { during.append(trace.crashKey(.inCEFPump)) }, timer: timer,
                                      clock: { 100 }, ledger: WakeupLedger(), crashKeys: nil, trace: trace)
            pump.start()
            timer.fire()
            #expect(during == [1], "in_cef_pump is 1 while CefDoMessageLoopWork runs")
            #expect(trace.crashKey(.inCEFPump) == 9, "the value before the pass once it returns")
            pump.stop()
        } when: { !Self.keepsCrashKeys(trace) }
    }

    /// A reentrant fire from a nested run loop puts `in_cef_pump` back to the value outside the pass, and the
    /// pass leaves it there once it returns.
    @Test func aNestedRunLoopInsideAPassPutsInCEFPumpBack() {
        let trace = Self.pumpTrace()
        withKnownIssue("078 crash-key page: a runtime with no page keeps no key") {
            trace.setCrashKey(.inCEFPump, 0)
            let keys = CrashKeySlots()
            var seen: [UInt64] = []
            var nested = false
            let timer = Timer()
            let pump = CEFMessagePump(work: {
                seen.append(trace.crashKey(.inCEFPump))
                guard !nested else { return }
                nested = true
                timer.fire()
                seen.append(trace.crashKey(.inCEFPump))
            }, timer: timer, clock: { 100 }, ledger: WakeupLedger(), crashKeys: keys, trace: trace)
            pump.start()
            timer.fire()
            #expect(seen == [1, 0], "in the pump, then the outer value once the nested loop fired it")
            #expect(pump.stats.reentrantFires == 1)
            #expect(trace.crashKey(.inCEFPump) == 0, "no key left at 1 after the pass")
            pump.stop()
        } when: { !Self.keepsCrashKeys(trace) }
    }

    @Test func aPumpWithNoCrashKeysStillRunsItsPasses() {
        var passes = 0
        let timer = Timer()
        let pump = CEFMessagePump(work: { passes += 1 }, timer: timer, clock: { 100 },
                                  ledger: WakeupLedger(), crashKeys: nil, trace: TraceRuntime(role: .app))
        pump.start()
        timer.fire()
        #expect(passes == 1)
        pump.stop()
    }

    /// A runtime of its own for the pump (078 attaches its `CrashKeyPage` here once it is on the base).
    private static func pumpTrace() -> TraceRuntime {
        TraceRuntime(role: .app)
    }

    /// Whether `trace` keeps a crash key it is given (false while no crash-key page is attached).
    private static func keepsCrashKeys(_ trace: TraceRuntime) -> Bool {
        let before = trace.crashKey(.inCEFPump)
        defer { trace.setCrashKey(.inCEFPump, before) }
        trace.setCrashKey(.inCEFPump, before &+ 1)
        return trace.crashKey(.inCEFPump) == before &+ 1
    }
}

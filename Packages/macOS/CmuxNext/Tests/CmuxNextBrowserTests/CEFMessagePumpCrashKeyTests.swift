import CmuxNextCompat
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// The CEF pump runs on the main thread, so it is a phase of the main thread's episode, not a
/// hang-watch scope (p10-stability-031): each pass runs with the `in_cef_pump` crash key set, which the
/// main-thread watchdog reads while the main thread is suspended and names `cef_pump` in its records.
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

    /// A crash-key page in memory.
    nonisolated final class Keys: CrashKeyStore {
        private let values = Mutex<[CrashKeySlot: UInt64]>([:])
        func setCrashKey(_ slot: CrashKeySlot, _ value: UInt64) { values.withLock { $0[slot] = value } }
        func crashKey(_ slot: CrashKeySlot) -> UInt64 { values.withLock { $0[slot] ?? 0 } }
    }

    @Test func aPassRunsWithTheCEFPumpCrashKeySetAndClearsItAfter() {
        let keys = Keys()
        var during: [UInt64] = []
        let timer = Timer()
        let pump = CEFMessagePump(work: { during.append(keys.crashKey(.inCEFPump)) }, safetyNet: .none, timer: timer,
                                  clock: { 100 }, ledger: WakeupLedger(), crashKeys: keys)
        pump.start()
        timer.fire()
        #expect(during == [1], "set while CefDoMessageLoopWork runs")
        #expect(keys.crashKey(.inCEFPump) == 0, "cleared once the pass returns")
        pump.stop()
    }
}

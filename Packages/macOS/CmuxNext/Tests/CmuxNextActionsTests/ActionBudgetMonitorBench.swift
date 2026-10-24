import CmuxNextWakeups
import Foundation
@testable import CmuxNextActions
import Testing

import Darwin

private func diagWrite(_ text: StaticString) { _ = write(2, text.utf8Start, text.utf8CodeUnitCount) }
private func diagHex(_ value: UInt) {
    var digits = [UInt8](repeating: 0, count: 18)
    digits[0] = 0x30; digits[1] = 0x78
    var v = value
    for i in stride(from: 17, through: 2, by: -1) { let d = UInt8(v & 0xF); digits[i] = d < 10 ? 0x30 + d : 0x57 + d; v >>= 4 }
    digits.withUnsafeBufferPointer { _ = write(2, $0.baseAddress, 18) }
    diagWrite("\n")
}

/// Diagnostic only (scratch ref): prints the fault address and a backtrace on SIGSEGV/SIGBUS, on an alternate stack.
private func installDiagCrashHandler() {
    let size = 1 << 20
    var alt = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16), ss_size: size, ss_flags: 0)
    sigaltstack(&alt, nil)
    var action = sigaction()
    action.__sigaction_u.__sa_sigaction = { sig, info, _ in
        diagWrite("DIAG-CRASH signal; fault address: ")
        diagHex(UInt(bitPattern: info?.pointee.si_addr))
        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
        let n = backtrace(frames, 128)
        backtrace_symbols_fd(frames, n, 2)
        signal(sig, SIG_DFL)
        raise(sig)
    }
    action.sa_flags = SA_SIGINFO | SA_ONSTACK
    sigaction(SIGSEGV, &action, nil)
    sigaction(SIGBUS, &action, nil)
}

/// The always-on cost of the per-action budget, in nanoseconds: what ``SignpostActionRunTiming``
/// adds to every run (two `CLOCK_UPTIME_RAW` reads and one
/// ``ActionBudgetMonitor/record(_:_:start:end:inputAgeMilliseconds:outcome:)`` with no reader),
/// and the hand-off of one batch to the reporter (one copy of ``ActionBudgetMonitor/batchSize``
/// runs and one yield, after a commit). A measurement, not a gate: run it in a Release build on
/// each macOS major and quote the line.
///
/// ```
/// CMUX_ACTION_BUDGET_BENCH=1 swift test -c release --filter ActionBudgetMonitorBench
/// ```
@MainActor
@Suite(.serialized)
struct ActionBudgetMonitorBench {
    private static let runs = 2_000_000

    /// Nanoseconds per run of `runs` records into `monitor` (under budget, no sample reader).
    private static func recordNanos(_ monitor: ActionBudgetMonitor, _ indices: [UInt32]) -> Double {
        let start = ActionBudgetMonitor.now()
        for index in 0..<runs {
            monitor.record(indices[index & 3], .key, start: UInt64(index), end: UInt64(index) &+ 1_000,
                           inputAgeMilliseconds: 1.5, outcome: .committed)
        }
        return Double(ActionBudgetMonitor.now() - start) / Double(runs)
    }

    @Test func alwaysOnCostPerRunAndPerBatch() async {
        let ids: [ActionID] = ["splitRight", "palette.toggleWorkspacePin", "newTab", "closeTab"]

        var clockSink: UInt64 = 0
        let clockStart = ActionBudgetMonitor.now()
        for _ in 0..<Self.runs { clockSink &+= ActionBudgetMonitor.now() }
        let clockNanos = Double(ActionBudgetMonitor.now() - clockStart) / Double(Self.runs)

        // No batch reader: the ring write and the counters only.
        let bare = ActionBudgetMonitor()
        let bareIndices = ids.map(bare.intern)
        _ = Self.recordNanos(bare, bareIndices)  // warm
        let perRun = Self.recordNanos(bare, bareIndices)

        // With the reporter's batch reader draining off the main actor.
        let batched = ActionBudgetMonitor()
        let batchedIndices = ids.map(batched.intern)
        let batches = batched.batches()
        let drain = Task.detached { var runs = 0; for await batch in batches { runs += batch.count }; return runs }
        let withBatches = Self.recordNanos(batched, batchedIndices)
        let batchCount = Double(Self.runs / batched.batchSize)
        let perBatch = (withBatches - perRun) * Double(Self.runs) / batchCount
        drain.cancel()

        // With the app's board attached: the span's begin and end (atomics) on every run, as in the app.
        let board = MainTaskBoard()
        let spanned = ActionBudgetMonitor(board: board)
        let spannedIndices = ids.map(spanned.intern)
        let spanStart = ActionBudgetMonitor.now()
        for index in 0..<Self.runs {
            let start = UInt64(index)
            let span = spanned.beginSpan(spannedIndices[index & 3], start: start)
            spanned.record(spannedIndices[index & 3], .key, start: start, end: start &+ 1_000, inputAgeMilliseconds: 1.5,
                           outcome: .committed, span: span)
        }
        let withSpan = Double(ActionBudgetMonitor.now() - spanStart) / Double(Self.runs)
        print(String(format: "action-budget bench: with the board span: %.1f ns/run (record + span begin and end)", withSpan))

        installDiagCrashHandler()
        let thread = pthread_self()
        print("DIAG main thread: \(Thread.isMainThread) stack top \(pthread_get_stackaddr_np(thread)) size \(pthread_get_stacksize_np(thread))")
        // Diagnostic: a no-op hook first, then the semaphore hook, each with progress markers.
        let noop = MainTaskBoard()
        noop.setTaskStartHook {}
        let noopMonitor = ActionBudgetMonitor(board: noop)
        let noopIndices = ids.map(noopMonitor.intern)
        print("DIAG no-op hook: start")
        for index in 0..<Self.runs {
            if index % 500_000 == 0 { print("DIAG no-op hook: \(index)") }
            let start = UInt64(index)
            let span = noopMonitor.beginSpan(noopIndices[index & 3], start: start)
            noopMonitor.record(noopIndices[index & 3], .key, start: start, end: start &+ 1_000, inputAgeMilliseconds: 1.5,
                               outcome: .committed, span: span)
        }
        print("DIAG no-op hook: done")
        // As in DEBUG and bench launches: the watchdog's task start hook is installed, so every span
        // begin copies it under its lock and signals a semaphore.
        let watched = MainTaskBoard()
        let wake = DispatchSemaphore(value: 0)
        watched.setTaskStartHook { wake.signal() }
        let hooked = ActionBudgetMonitor(board: watched)
        let hookedIndices = ids.map(hooked.intern)
        let hookStart = ActionBudgetMonitor.now()
        print("DIAG semaphore hook: start")
        for index in 0..<Self.runs {
            if index % 500_000 == 0 { print("DIAG semaphore hook: \(index)") }
            let start = UInt64(index)
            let span = hooked.beginSpan(hookedIndices[index & 3], start: start)
            hooked.record(hookedIndices[index & 3], .key, start: start, end: start &+ 1_000, inputAgeMilliseconds: 1.5,
                          outcome: .committed, span: span)
        }
        print("DIAG semaphore hook: done")
        let withHook = Double(ActionBudgetMonitor.now() - hookStart) / Double(Self.runs)
        print(String(format: "action-budget bench: with the span and the watchdog hook (DEBUG, bench launches): %.1f ns/run "
                     + "(not the whole time() path: input age, signpost message and commit observers are not in it)", withHook))

        let line = String(format: "action-budget bench: macOS %@, %d runs: record %.1f ns/run, clock read %.1f ns, always-on %.1f ns/run; "
                          + "batch hand-off %.0f ns per %d runs (%.1f ns/run amortized, %llu runs dropped) (sink %llu)",
                          ProcessInfo.processInfo.operatingSystemVersionString, Self.runs, perRun, clockNanos, perRun + 2 * clockNanos,
                          perBatch, batched.batchSize, withBatches - perRun, batched.droppedRunCount, clockSink & 1)
        print("DIAG final line next")
        print(line)
        #expect(bare.runCount == UInt64(2 * Self.runs))
    }
}

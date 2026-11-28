extension MainThreadWatchdog {
    /// A stall past `assertNanos` is a busy hang only when the main thread used CPU for at least
    /// half the threshold. A backgrounded app (App Nap, background role) can leave the heartbeat
    /// stale while the main thread idles in `mach_msg` or barely gets scheduled, and a thread
    /// blocked on a lock, a synchronous IPC or a kernel call (an IOKit registry read on a Mac at
    /// load 334 on 15 cores, https://github.com/manaflow-ai/cmux/issues/50992) uses no CPU either:
    /// those are hangs (``onHang``), not busy ones. When the CPU time is unknown (`nil`) nothing
    /// proves the main thread was busy, so it is not one.
    static func hangIsBusy(elapsedNanos: UInt64, mainThreadCPUNanos: UInt64?, assertNanos: UInt64) -> Bool {
        guard elapsedNanos >= assertNanos, let mainThreadCPUNanos else { return false }
        return mainThreadCPUNanos >= assertNanos / 2
    }

    /// Whether the stall heartbeat `beat` began is, `elapsedNanos` in, a busy hang still running.
    /// The check runs after the hang was reported (a stack sample and a hang file), and on a Mac
    /// out of CPU the watchdog thread waits for its turn like the main thread, so the stall can end
    /// in between: its CPU reading is then gone with its heartbeat (``mainThreadCPU(sinceBeat:)``
    /// answers nil). The heartbeat is read again after the CPU time, so a reading that came back
    /// belongs to a stall still running. Watchdog thread.
    func runningHangIsBusy(beat: UInt64, elapsedNanos: UInt64, assertNanos: UInt64) -> Bool {
        let cpu = mainThreadCPU(sinceBeat: beat)
        guard beatSequence.load(ordering: .acquiring) == beat, !mainAsleep.load(ordering: .acquiring) else { return false }
        return Self.hangIsBusy(elapsedNanos: elapsedNanos, mainThreadCPUNanos: cpu, assertNanos: assertNanos)
    }
}

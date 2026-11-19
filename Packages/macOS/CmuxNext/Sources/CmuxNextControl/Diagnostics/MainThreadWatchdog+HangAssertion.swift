import CmuxNextCompat

extension MainThreadWatchdog {
    /// A stall past `assertNanos` fails the debug assertion only when the
    /// main thread was busy: it used CPU for at least half the threshold.
    /// A backgrounded app (App Nap, background role) can leave the heartbeat
    /// stale while the main thread idles in `mach_msg` or barely gets
    /// scheduled; that is reported as a hang but is no main-thread bug. A
    /// thread blocked on a lock or a synchronous IPC uses no CPU either; it
    /// too is reported (``onHang``), not asserted. When the CPU time cannot
    /// be read (`nil`), wall-clock time alone decides.
    static func hangFailsAssertion(elapsedNanos: UInt64, mainThreadCPUNanos: UInt64?, assertNanos: UInt64) -> Bool {
        guard elapsedNanos >= assertNanos else { return false }
        guard let mainThreadCPUNanos else { return true }
        return mainThreadCPUNanos >= assertNanos / 2
    }

    /// Whether the stall heartbeat `beat` began, `elapsedNanos` old when the watchdog thread measured it,
    /// fails the debug assertion now. Only a stall still running does. The check runs after the hang is
    /// reported (a stack sample and a hang file), and on a Mac out of CPU the watchdog thread waits for
    /// its turn like the main thread, so the stall can end in between. Its CPU reading is then gone with
    /// its heartbeat (``mainThreadCPU(sinceBeat:)`` answers nil), and that nil is not "the CPU time cannot
    /// be read": an app whose main thread got 2 ms in an 11 s stall (host load 128 on 15 cores) was ended
    /// by this assertion. The heartbeat is read after the CPU time, so a reading that came back belongs
    /// to this stall.
    func runningHangFailsAssertion(beat: UInt64, elapsedNanos: UInt64, assertNanos: UInt64) -> Bool {
        let cpu = mainThreadCPU(sinceBeat: beat)
        guard beatSequence.load(ordering: .acquiring) == beat else { return false }
        return Self.hangFailsAssertion(elapsedNanos: elapsedNanos, mainThreadCPUNanos: cpu, assertNanos: assertNanos)
    }
}

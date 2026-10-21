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
}

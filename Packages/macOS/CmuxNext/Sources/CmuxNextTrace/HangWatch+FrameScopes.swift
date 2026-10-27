import CmuxNextCompat

/// Scopes whose open and close are two calls, not one ``HangWatchScope``: a C hook's frame begin and end
/// (Ghostty's renderer threads, p09-observability-120). Their slots wake the monitor through a kernel timer
/// lease rather than at each open, so a thread that draws while the process is otherwise idle adds no wakeup.
extension HangWatch {
    /// Opens an unnested scope whose open and close are two separate calls, such as a C hook's frame begin
    /// and end (Ghostty's renderer, p09-observability-120), where no ``HangWatchScope`` can live from one
    /// call to the next. It replaces any scope open on the slot, so a begin whose end never came does not
    /// nest the next one; only use it on a slot that ``watch(_:deadline:)`` never opens. On a thread's slot
    /// (``registerThread(_:name:subject:)``), a call from another thread does nothing: the stack sample would
    /// be the wrong thread's.
    ///
    /// Its scopes never wake the monitor. They are for a thread that wakes on its own, often, when nothing
    /// else does (a renderer drawing a blinking cursor), where a wake per scope would be the process's idle
    /// wakeups. The slot keeps a lease instead: the monitor's kernel timer for the slot
    /// (``attachMonitor(wake:leaseTimer:)``), set to fire one budget past the scope's deadline and moved later
    /// only when a scope opens past its fire time. While scopes keep closing, the timer never fires; a scope
    /// still open when it fires is scanned then, so its jank is seen up to one budget late and its hang tier
    /// on time. Cost: the clock read, one exchange, two loads and, at most once per budget, the timer's system
    /// call on this thread. With no slot timers, a scope wakes the monitor as ``watch(_:deadline:)``'s do.
    @inline(__always)
    public func begin(_ registration: Registration, deadline: Duration) {
        guard let live = ownSlot(registration) else { return }
        let opened = stamp(live, deadline: deadline)
        guard opened.due != 0, !renewLease(live.slot, index: Int(truncatingIfNeeded: registration.slot), opened: opened) else { return }
        requestScan(by: opened.due)
    }

    /// Closes the scope ``begin(_:deadline:)`` opened on `registration`'s slot: one compare-and-swap; with
    /// no scope open, it leaves the slot closed. From another thread than a thread slot's own, nothing.
    @inline(__always)
    public func end(_ registration: Registration) {
        guard let live = ownSlot(registration) else { return }
        close(slotAddress: UInt(bitPattern: live.slot), registration: registration, previous: 0)
    }

    /// The slot while `registration` owns it and, for a thread's slot, the caller is that thread.
    @inline(__always)
    private func ownSlot(_ registration: Registration) -> (slot: UnsafeMutablePointer<UInt64>, state: UInt64)? {
        guard let live = liveSlot(registration) else { return nil }
        guard live.state & Self.kindMask == UInt64(ThreadKind.lane.rawValue)
            || Self.word(live.slot, Self.portWord).load(ordering: .relaxed) == Self.currentPort() else { return nil }
        return live
    }

    /// Keeps a ``begin(_:deadline:)`` slot's kernel timer firing no later than one budget past the scope that
    /// just opened, and the monitor's plan no later than that timer, so the wake the timer makes is a scan.
    /// The timer moves (one system call) only when it would fire before the scope's deadline.
    ///
    /// - Returns: false when the monitor has no slot timers: the caller wakes it instead.
    @inline(__always)
    private func renewLease(_ slot: UnsafeMutablePointer<UInt64>, index: Int,
                            opened: (previous: UInt64, due: UInt64, now: UInt64)) -> Bool {
        var planned = plan.load(ordering: .sequentiallyConsistent)
        guard planned != 0 else { return true } // no monitor: nothing scans, nothing to wake
        let box = wakeBox.load(ordering: .acquiring)
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: box)) else { return false }
        let monitor = Unmanaged<WakeBox>.fromOpaque(pointer)
        guard monitor._withUnsafeGuaranteedRef({ $0.leaseTimer != nil }) else { return false }
        let lease = Self.word(slot, Self.leaseWord)
        var fire = lease.load(ordering: .relaxed)
        if fire < opened.due {
            let (sum, overflow) = opened.due.addingReportingOverflow((slot + Self.timeoutNanosWord).pointee)
            fire = overflow ? Self.deadlineMask : min(sum, Self.deadlineMask)
            monitor._withUnsafeGuaranteedRef { $0.leaseTimer?(index, fire &- opened.now) }
            leases.add(1, ordering: .relaxed)
            lease.store(fire, ordering: .relaxed)
        }
        // The plan a lease sets counts as published: the slot's timer, not the scan period, covers this slot.
        while planned > fire {
            let (exchanged, original) = plan.compareExchange(expected: planned, desired: fire, ordering: .sequentiallyConsistent)
            if exchanged {
                published.store(fire, ordering: .relaxed)
                break
            }
            planned = original // 0: detached meanwhile, which ends the loop
        }
        return true
    }
}

import CmuxNextCompat

/// The monitor's side of the slot table: one thread (the app's main-thread watchdog thread, through
/// `HangMonitor` in CmuxNextControl) scans the slots when ``nextScanNanos`` comes, and reports what
/// ``scan(nowNanos:)`` returns as overdue.
///
/// The rule (p09-observability.md section 3E, p02-threads.md section E):
/// - While scopes open and close, the monitor scans once per ``HangWatch/minimumDeadline``: a scope that
///   opens then is seen at most one period past its deadline, and wakes nobody.
/// - After a scan in which no slot changed, it sleeps to the earliest open deadline, with no periodic
///   wake (a 30 s job alone costs the wake that started the watch and, if it overruns, its report).
/// - With nothing open, it parks with no timer: an idle process has no hang-watch wakeup, where Chrome's
///   watcher polls every 10 s.
/// - A scope whose deadline would be seen more than one period late (the monitor is parked, or sleeps to
///   a later deadline) moves the plan to its deadline and calls the monitor's wake: the first open after a
///   park, one wake each.
///
/// A scan publishes `.max` as the plan before it reads the slots, so a scope that opens during the scan
/// sees it and wakes the monitor, and the scan's own plan never hides that scope.
extension HangWatch {
    /// One scope past its deadline, marked reported (``scan(nowNanos:)``).
    public struct Overdue: Sendable {
        /// The registration's name (``registerThread(_:name:)``, ``registerLane(_:)``).
        public let name: String
        /// What the slot runs (``ThreadKind/lane`` for a lane).
        public let kind: ThreadKind?
        /// The Mach port of the thread running the scope (`pthread_mach_thread_np`), for its stack sample.
        public let port: UInt32
        /// When the scope's deadline passed (`CLOCK_UPTIME_RAW` nanoseconds).
        public let deadlineNanos: UInt64
        let slot: Int
        let marked: UInt64
    }

    /// What one scan found, and when the next one is due.
    public struct ScanResult: Sendable {
        /// Scopes past their deadline, each returned once.
        public let overdue: [Overdue]
        /// When to scan next (`CLOCK_UPTIME_RAW` nanoseconds); nil: parked until a scope wakes the monitor.
        public let nextScanNanos: UInt64?
    }

    /// Connects the one monitor: from now on a scope that needs an earlier scan calls `wake` (on its own
    /// thread; it must return at once, as a kqueue user-event trigger does). The monitor starts parked.
    ///
    /// - Returns: false when a monitor is connected already (this one is not).
    @discardableResult
    public func attachMonitor(wake: @escaping @Sendable () -> Void) -> Bool {
        let box = Unmanaged.passRetained(WakeBox(wake))
        let address = UInt64(truncatingIfNeeded: UInt(bitPattern: box.toOpaque()))
        guard wakeBox.compareExchange(expected: 0, desired: address, ordering: .acquiringAndReleasing).exchanged else {
            box.release()
            return false
        }
        published.store(.max, ordering: .relaxed)
        plan.store(.max, ordering: .sequentiallyConsistent)
        return true
    }

    /// Disconnects the monitor for good (it stops): no scope wakes it again, and ``scan(nowNanos:)``
    /// returns nothing.
    public func detachMonitor() {
        plan.store(0, ordering: .sequentiallyConsistent)
    }

    /// When the monitor scans next (`CLOCK_UPTIME_RAW` nanoseconds); nil while it is parked or detached.
    public var nextScanNanos: UInt64? {
        let planned = plan.load(ordering: .acquiring)
        return planned == 0 || planned == .max ? nil : planned
    }

    /// Now on the clock of every deadline.
    public func nowNanos() -> UInt64 { clock.nowNanos() }

    /// Scans every slot (monitor thread only): marks each scope past its deadline reported and returns
    /// it, and plans the next scan by the rule above.
    ///
    /// - Parameter now: Now, from ``nowNanos()``.
    /// - Returns: The overdue scopes and the next scan.
    public func scan(nowNanos now: UInt64) -> ScanResult {
        var planned = plan.load(ordering: .sequentiallyConsistent)
        while planned != 0 {
            let (exchanged, original) = plan.compareExchange(expected: planned, desired: .max, ordering: .sequentiallyConsistent)
            if exchanged { break }
            planned = original
        }
        guard planned != 0 else { return ScanResult(overdue: [], nextScanNanos: nil) } // detached
        // A plan the monitor did not publish: a scope moved it (and opened or closed since).
        var changed = planned != published.load(ordering: .relaxed)
        var earliest = UInt64.max
        var overdue: [Overdue] = []
        for index in 0..<min(claimedEnd.load(ordering: .acquiring), Self.capacity) {
            guard let slot = slot(at: index) else { continue }
            let word = Self.word(slot, Self.deadlineWord)
            let current = word.load(ordering: .sequentiallyConsistent)
            let seen = slot + Self.seenWord
            if seen.pointee != current {
                changed = true
                seen.pointee = current
            }
            let due = current & Self.deadlineMask
            guard due != 0, current & Self.flagMask == 0 else { continue }
            guard due <= now else {
                earliest = min(earliest, due)
                continue
            }
            let marked = current | Self.reportedFlag
            guard word.compareExchange(expected: current, desired: marked, ordering: .acquiringAndReleasing).exchanged else {
                changed = true // the scope ended or nested meanwhile: look again next period
                continue
            }
            seen.pointee = marked
            let state = Self.word(slot, Self.stateWord).load(ordering: .relaxed)
            overdue.append(Overdue(name: Self.unpack(Self.word(slot, Self.nameWord).load(ordering: .relaxed)),
                                   kind: ThreadKind(rawValue: UInt8(truncatingIfNeeded: state & Self.kindMask)),
                                   port: UInt32(truncatingIfNeeded: Self.word(slot, Self.portWord).load(ordering: .relaxed)),
                                   deadlineNanos: due, slot: index, marked: marked))
        }
        let next = changed ? now &+ periodNanos : earliest // `.max`: park
        var final = next
        var expected = UInt64.max
        while expected != 0 {
            let (exchanged, original) = plan.compareExchange(expected: expected, desired: final, ordering: .sequentiallyConsistent)
            if exchanged { break }
            // A scope woke the monitor during the scan: keep its earlier deadline. 0: detached meanwhile.
            expected = original
            final = original == 0 ? 0 : min(original, next)
        }
        published.store(final, ordering: .relaxed)
        return ScanResult(overdue: overdue, nextScanNanos: final == 0 || final == .max ? nil : final)
    }

    /// Whether `overdue`'s scope is still open (its stack, sampled after the scan, is still its own).
    public func isStillOpen(_ overdue: Overdue) -> Bool {
        guard let slot = slot(at: overdue.slot) else { return false }
        return Self.word(slot, Self.deadlineWord).load(ordering: .acquiring) == overdue.marked
    }
}

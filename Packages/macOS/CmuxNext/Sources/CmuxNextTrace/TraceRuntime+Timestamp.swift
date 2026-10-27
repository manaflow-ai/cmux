import CmuxNextCompat

extension TraceRuntime {
    /// Writes one whole async slice (AB, then AE, both keyed by `id`) whose begin and end times are known
    /// already, when the category is on: a span that began before anything could write it (the process start)
    /// and ends now. Chrome's startup metrics write their spans the same way, a begin and an end with given
    /// times on one track per name (components/startup_metric_utils/common/startup_metric_utils.cc,
    /// `EmitTraceEvent`). The category is read once, so the ring never holds one record without the other.
    ///
    /// - Parameters:
    ///   - name: The catalog id (`SignpostName.rawValue`).
    ///   - categoryBit: The category's bit (`SignpostCategory.traceBit`).
    ///   - id: The async id both records carry in `arg1`.
    ///   - beginNanos: The begin's trace-clock time (``TraceClock``).
    ///   - endNanos: The end's trace-clock time.
    ///   - beginFlags: Flags of the begin besides ``RecordFlags/asyncID`` (``RecordFlags/estimated`` for a time
    ///     computed from another clock).
    ///   - beginArg0: The begin's first number.
    ///   - endArg0: The end's first number.
    /// - Returns: Whether the slice was written (its category was on).
    @discardableResult
    public func writeAsyncSlice(name: UInt16, categoryBit: UInt8, id: UInt64, beginNanos: UInt64, endNanos: UInt64,
                                beginFlags: RecordFlags = [], beginArg0: UInt64 = 0, endArg0: UInt64 = 0) -> Bool {
        guard isEnabled(categoryBit: categoryBit) else { return false }
        publish(name: name, categoryBit: categoryBit, phase: .asyncBegin, flags: beginFlags.union(.asyncID),
                timestamp: beginNanos, arg0: beginArg0, arg1: id)
        publish(name: name, categoryBit: categoryBit, phase: .asyncEnd, flags: .asyncID, timestamp: endNanos,
                arg0: endArg0, arg1: id)
        return true
    }

    /// Publishes one catalog record stamped `timestamp` into the attached ring, or to the test's stub when no
    /// ring is attached.
    private func publish(name: UInt16, categoryBit: UInt8, phase: Phase, flags: RecordFlags, timestamp: UInt64,
                         arg0: UInt64, arg1: UInt64) {
        guard let ring else {
            stubRecordCount.add(1, ordering: .relaxed) // No ring attached (a test's runtime): count what passed the gate.
            stubRecorder?(StubRecord(tNanos: timestamp, name: name, categoryBit: categoryBit, phase: phase,
                                     flags: flags, arg0: arg0, arg1: arg1))
            return
        }
        ring.write(name: name, phase: phase.recordPhase, flags: flags.rawValue, timestamp: timestamp, arg0: arg0, arg1: arg1)
    }
}

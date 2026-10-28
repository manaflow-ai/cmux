import CmuxNextCompat

/// Records that name a source site: Chrome's `FROM_HERE` (base/location.h), which every `PostTask` carries and
/// `TaskAnnotator` writes with the post and the run (base/task/common/task_annotator.cc). Perfetto interns the
/// file and keeps the line as a number (`protos/perfetto/trace/track_event/source_location.proto`); a site record
/// does the same: `arg0` holds the file's interned id in bits 0-15 and the line in bits 16-47.
extension TraceRuntime {
    /// The highest line a site record holds (32 bits); a later line is written as this one.
    public static let maxSiteLine: UInt = 0xFFFF_FFFF

    /// Trace clock nanoseconds now: the time a record written now carries (also a lane item's post time, for its
    /// queue wait).
    public func nowNanos() -> UInt64 {
        clock.nowNanos()
    }

    /// Writes one catalog record whose `arg0` names a source site, when its category is on: `file`'s id in the
    /// ring the record goes to in bits 0-15 (0 when `file` is nil or the name table is full) and `line` in bits
    /// 16-47. The id comes from the same ring as the record, also when an adoption swaps the active ring
    /// between the two (trace.md "Name table").
    ///
    /// - Parameters:
    ///   - name: The catalog id (`SignpostName.rawValue`).
    ///   - categoryBit: The category's bit (`SignpostCategory.traceBit`).
    ///   - phase: What the record marks.
    ///   - file: The site's file (a `#fileID`), interned in each ring at its first record there.
    ///   - line: The site's line.
    ///   - arg1: The second number (a flow id for a flow record).
    /// - Returns: The record's trace clock time, or nil when its category is off.
    @discardableResult
    public func write(name: UInt16, categoryBit: UInt8, phase: Phase, file: InternedName?, line: UInt,
                      arg1: UInt64) -> UInt64? {
        guard isEnabled(categoryBit: categoryBit) else { return nil }
        let timestamp = clock.nowNanos()
        let lineBits = UInt64(min(line, Self.maxSiteLine)) << 16
        guard let raw = UnsafeRawPointer(bitPattern: UInt(ringAddress.load(ordering: .acquiring))) else {
            stubRecordCount.add(1, ordering: .relaxed) // No ring attached (a test's runtime): count what passed the gate.
            stubRecorder?(StubRecord(tNanos: timestamp, name: name, categoryBit: categoryBit, phase: phase, flags: [],
                                     arg0: lineBits, arg1: arg1))
            return timestamp
        }
        Unmanaged<TraceRing>.fromOpaque(raw)._withUnsafeGuaranteedRef {
            $0.write(name: name, phase: phase.recordPhase, timestamp: timestamp, file: file, lineBits: lineBits, arg1: arg1)
        }
        return timestamp
    }
}

extension TraceRing {
    /// Appends one record whose `arg0` is `file`'s id in the active ring ORed with `lineBits`, the ring loaded once.
    func write(name: UInt16, phase: TraceRecord.Phase, timestamp: UInt64, file: TraceRuntime.InternedName?,
               lineBits: UInt64, arg1: UInt64) {
        guard let active = activeRing else { return }
        let id = file?.id(inSlot: active.pointee.slot, of: active.pointee.storage) ?? 0
        write(into: active, name: name, phase: phase, flags: 0, timestamp: timestamp, arg0: lineBits | UInt64(id), arg1: arg1)
    }
}

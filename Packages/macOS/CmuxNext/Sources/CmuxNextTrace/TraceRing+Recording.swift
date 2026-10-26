import CmuxNextCompat

/// A ring's recording (trace.md "Recording ring", p09-observability task 020): the black box's ring keeps a
/// second, larger ring that a `trace.start` points every writer at and a `trace.stop` points back from. The
/// recording ring is mapped once (``TraceBlackBox/prepareRecording()``) and never unmapped; each start moves
/// its cursor a lap past the last recording, so the decoder reads only the current one. Perfetto's tracing
/// service reuses a session's buffers the same way (src/tracing/service/tracing_service_impl.cc).
extension TraceRing {
    /// The recording ring, nil until ``attachRecording(_:path:)``.
    var recordingRing: UnsafeMutablePointer<TraceRingActive>? {
        UnsafeMutablePointer(bitPattern: UInt(recordingCell.load(ordering: .acquiring)))
    }

    /// Whether a recording holds the writers.
    public var isRecording: Bool {
        recordingPhase.load(ordering: .acquiring) == RecordingPhase.recording.rawValue
    }

    /// Keeps `storage`, an initialized recording ring mapped at `path`, as this ring's recording ring for the
    /// process's life. No writer sees it before ``beginRecording(at:)``.
    ///
    /// - Returns: false when one is attached already (the first one stays; `storage` is never used).
    func attachRecording(_ storage: TraceRingStorage, path: String) -> Bool {
        let made = TraceRingActive.make(storage, slot: TraceRingActive.recordingSlot, path: path)
        let address = UInt64(UInt(bitPattern: made))
        guard recordingCell.compareExchange(expected: 0, desired: address, ordering: .acquiringAndReleasing).exchanged else {
            made.deinitialize(count: 1)
            made.deallocate()
            return false
        }
        return true
    }

    /// `trace.start` for this ring: resets the recording ring's counters and start times, moves its cursor a
    /// lap past every chunk of the last recording (so the decoder reads only this one), then points every
    /// writer at it. Rust's `Tracer::start_recording` (cmux-trace/src/tracer.rs) takes the same steps.
    ///
    /// - Parameter times: The recording's start on the header's three clocks.
    /// - Returns: false when no recording ring is attached, or a recording runs or is changing.
    func beginRecording(at times: RecordingStart) -> Bool {
        guard let recording = recordingRing else { return false }
        guard recordingPhase.compareExchange(expected: RecordingPhase.idle.rawValue, desired: RecordingPhase.changing.rawValue,
                                             ordering: .acquiringAndReleasing).exchanged else { return false }
        recording.pointee.storage.beginRecording(at: times)
        // A new activation per recording (never freed, like every activation): a thread still holding a chunk
        // of the last recording sees the active ring change, completes that chunk and claims one in this lap,
        // instead of writing into a lap the decoder skips (Rust bumps the active word's epoch the same way).
        let activation = TraceRingActive.make(recording.pointee.storage, slot: TraceRingActive.recordingSlot, path: recording.pointee.path)
        activeCell.store(UInt64(UInt(bitPattern: activation)), ordering: .releasing)
        recordingPhase.store(RecordingPhase.recording.rawValue, ordering: .releasing)
        return true
    }

    /// `trace.stop` for this ring: points the writers back at the black box. The recording ring keeps its
    /// records until the next start.
    ///
    /// - Returns: false when no recording runs.
    func endRecording() -> Bool {
        guard recordingPhase.compareExchange(expected: RecordingPhase.recording.rawValue, desired: RecordingPhase.changing.rawValue,
                                             ordering: .acquiringAndReleasing).exchanged else { return false }
        // An adoption that swaps the black box to its file meanwhile leaves the writers on the recording, so
        // the writers go to the black box read last.
        var target = blackBoxCell.load(ordering: .acquiring)
        while true {
            activeCell.store(target, ordering: .releasing)
            let now = blackBoxCell.load(ordering: .acquiring)
            if now == target { break }
            target = now
        }
        recordingPhase.store(RecordingPhase.idle.rawValue, ordering: .releasing)
        return true
    }

    /// The recording ring's file and size, nil before ``attachRecording(_:path:)``.
    var recordingFile: (path: String, bytes: Int)? {
        recordingRing.map { ($0.pointee.path ?? "", $0.pointee.storage.layout.totalBytes) }
    }

    /// Stores `mask` into the black box's header `categories` word and, while a recording runs, the
    /// recording ring's (trace.md "Header": mirrored on each change), so a reader of either file knows what
    /// it recorded.
    func mirrorCategories(_ mask: UInt64) {
        blackBoxRing?.pointee.storage.word(TraceRingOffsets.categories).store(mask, ordering: .relaxed)
        if let active = activeRing, active.pointee.slot == TraceRingActive.recordingSlot {
            active.pointee.storage.word(TraceRingOffsets.categories).store(mask, ordering: .relaxed)
        }
    }

    /// A recording's start on the header's three clocks.
    struct RecordingStart {
        /// `CLOCK_UPTIME_RAW` nanoseconds (``TraceClock``).
        var uptimeNanos: UInt64
        /// Wall clock nanoseconds since 1970.
        var unixNanos: UInt64
        /// `CLOCK_MONOTONIC_RAW` nanoseconds (counts sleep).
        var continuousNanos: UInt64
    }

    /// Whether a recording holds the writers, and whether a start or stop is changing that.
    enum RecordingPhase: UInt64 {
        case idle = 0
        case changing = 1
        case recording = 2
    }
}

extension TraceRingStorage {
    /// Steps 1 and 2 of a recording's start (trace.md "Recording ring"; Rust's `Ring::begin_recording`):
    /// zero the chunk counters, store the start times, and move `chunk_cursor` a lap past every claim of an
    /// earlier recording, storing that cursor as `recording_start_cursor` so the decoder skips older laps.
    func beginRecording(at times: TraceRing.RecordingStart) {
        for counter in [TraceRingOffsets.chunksSkipped, TraceRingOffsets.recordsDropped, TraceRingOffsets.chunksOverwritten] {
            word(counter).store(0, ordering: .relaxed)
        }
        word(TraceRingOffsets.startUptime).store(times.uptimeNanos, ordering: .relaxed)
        word(TraceRingOffsets.startUnix).store(times.unixNanos, ordering: .relaxed)
        word(TraceRingOffsets.startContinuous).store(times.continuousNanos, ordering: .relaxed)
        let count = UInt64(layout.chunkCount)
        let claim = word(TraceRingOffsets.chunkCursor).add(count, ordering: .relaxed).oldValue
        word(TraceRingOffsets.recordingStartCursor).store(claim &+ count, ordering: .releasing)
    }
}

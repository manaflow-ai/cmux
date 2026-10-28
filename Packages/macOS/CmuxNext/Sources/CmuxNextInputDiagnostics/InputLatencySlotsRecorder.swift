public import CmuxNextInput
public import CmuxNextInputCore
public import CmuxNextWakeups

/// `debug.input` action `slots`: the app tracker's newest closed input latency slots, one row per input, newest first
/// (at most the ring's 256). The `latency` section folds every slot into histograms; this one keeps each key apart, so
/// a bench can put each key's latency against the time since its tab opened (first-seconds-lag.md). One main-thread
/// copy of the ring per request (an `automation` task on the app's scheduler); nothing per event.
///
/// Rows since the last `reset`, or every row the ring still holds with `since_launch`.
///
/// ```swift
/// let slots = InputLatencySlotsRecorder(tracker: services.inputLatency.tracker, mainWork: services.mainWork)
/// let debugInput = DebugInput(sources: [], recorders: [slots])
/// ```
public nonisolated struct InputLatencySlotsRecorder: DebugInputRecorder {
    private let tracker: InputLatencyTracker
    private let mainWork: MainWorkScheduler
    private let mark: Mark

    /// The tracker's closed-slot count at the last reset.
    @MainActor
    final class Mark {
        var closedAtReset: UInt64 = 0

        nonisolated init() {}
    }

    /// - Parameters:
    ///   - tracker: The app's one tracker.
    ///   - mainWork: The app's main-thread scheduler, which runs each request's copy.
    public init(tracker: InputLatencyTracker, mainWork: MainWorkScheduler) {
        self.tracker = tracker
        self.mainWork = mainWork
        mark = Mark()
    }

    public var kind: DebugInputRecorderKind { .slots }

    public func rows(sinceLaunch: Bool) async -> DebugInputSlots {
        await mainWork.apply(.automation, owner: "debug.input.slots") { [tracker, mark] in
            let fresh = tracker.closedCount &- mark.closedAtReset
            let wanted = sinceLaunch ? Int.max : Int(clamping: fresh)
            return DebugInputSlots(closed: tracker.closedCount, nowNanos: InputLatencyTracker.uptimeNanos(),
                                   slots: tracker.recent(wanted).map(DebugInputSlots.Slot.init))
        }
    }

    public func reset() async {
        await mainWork.apply(.automation, owner: "debug.input.slots") { [tracker, mark] in mark.closedAtReset = tracker.closedCount }
    }
}

/// The JSON of `debug.input slots`. Enum case names and numbers only: no user text.
public nonisolated struct DebugInputSlots: Encodable, Sendable, Equatable {
    /// One closed input.
    public nonisolated struct Slot: Encodable, Sendable, Equatable {
        public var kind: String
        public var target: String
        public var entrypoint: String
        public var presentationSource: String
        /// The input's OS event time, `CLOCK_UPTIME_RAW` nanoseconds (`NSEvent.timestamp`'s clock).
        public var generatedNanos: UInt64
        /// Generated to presented, or nil when the input has no presented frame (no echo, a missed commit).
        public var totalMilliseconds: Double?
        /// Each stage the input reached after `generated`: milliseconds since `generated`.
        public var stagesMilliseconds: [String: Double]
        public var causedFrameUpdate: Bool

        init(_ slot: InputLatencySlot) {
            kind = String(describing: slot.kind)
            target = String(describing: slot.target)
            entrypoint = String(describing: slot.entrypoint)
            presentationSource = String(describing: slot.presentationSource)
            generatedNanos = slot.generated
            totalMilliseconds = slot.totalNanos.map { Double($0) / 1e6 }
            var stages: [String: Double] = [:]
            for stage in InputStage.allCases where stage != .generated {
                if let nanos = slot.nanos(from: .generated, to: stage) { stages[String(describing: stage)] = Double(nanos) / 1e6 }
            }
            stagesMilliseconds = stages
            causedFrameUpdate = slot.causedFrameUpdate
        }

        private enum CodingKeys: String, CodingKey {
            case kind, target, entrypoint
            case presentationSource = "presentation_source"
            case generatedNanos = "generated_ns"
            case totalMilliseconds = "total_ms"
            case stagesMilliseconds = "stages_ms"
            case causedFrameUpdate = "caused_frame_update"
        }
    }

    /// Slots the tracker closed since launch.
    public var closed: UInt64
    /// `CLOCK_UPTIME_RAW` nanoseconds when the rows were copied.
    public var nowNanos: UInt64
    /// Newest first.
    public var slots: [Slot]

    private enum CodingKeys: String, CodingKey {
        case closed
        case nowNanos = "now_ns"
        case slots
    }
}

/// Where a reader gets closed input latency slots one by one, as they close: the Debug latency HUD
/// (CmuxNextFocusUI) reads it only while it is shown, so a closed HUD costs the producer no reader.
///
/// A producer (the input ring's writer, through `InputLatencyReporter`) keeps the newest closed
/// slots and one continuation per reader; it yields from its own thread and never waits on a
/// reader. Chrome's `EventLatency` tracing works the same way: the per-event breakdown is only
/// emitted while a trace category is enabled (cc/metrics/compositor_frame_reporter.cc).
public protocol InputLatencyFeed: Sendable {
    /// The closed slots: first the newest `count` already closed (oldest of them first), then each
    /// new one as it closes. The stream ends, and the producer forgets the reader, when the
    /// iterating task is cancelled. A slot that does not fit the reader's buffer is dropped; the
    /// producer never blocks.
    ///
    /// - Parameter count: How many already closed slots to replay.
    /// - Returns: The stream.
    func closedSlots(replaying count: Int) -> AsyncStream<InputLatencySlot>
}

/// The interval of one input that took the longest: from the stage it reached just before `to`,
/// to `to` (Chrome's EventLatency stage breakdowns, cc/metrics/compositor_frame_reporter.cc).
public struct InputLatencyDominantStage: Sendable, Equatable {
    /// The stage the interval starts at.
    public var from: InputStage
    /// The stage the interval ends at; the ledger files the interval under it.
    public var to: InputStage
    /// The interval.
    public var nanos: UInt64

    public init(from: InputStage, to: InputStage, nanos: UInt64) {
        self.from = from
        self.to = to
        self.nanos = nanos
    }
}

extension InputLatencySlot {
    /// The longest interval between two stages the input reached one after the other, or nil when
    /// it reached fewer than two. Stages follow each other by time, equal times in declaration
    /// order, and ``InputStage/lastGenerated`` is not a pipeline stage: the same intervals
    /// ``InputLatencyLedger`` folds into its stage histograms. The first of equal intervals wins.
    public var dominantStage: InputLatencyDominantStage? {
        var reached: [(stage: InputStage, time: UInt64)] = []
        reached.reserveCapacity(InputLatencyLedger.stageCount)
        for stage in InputStage.allCases where stage != .lastGenerated {
            let time = self[stage]
            if time != 0 { reached.append((stage, time)) }
        }
        reached.sort { $0.time != $1.time ? $0.time < $1.time : $0.stage.rawValue < $1.stage.rawValue }
        var dominant: InputLatencyDominantStage?
        for index in reached.indices.dropFirst() {
            let previous = reached[index - 1]
            let current = reached[index]
            let nanos = current.time - previous.time
            if dominant.map({ nanos > $0.nanos }) ?? true {
                dominant = InputLatencyDominantStage(from: previous.stage, to: current.stage, nanos: nanos)
            }
        }
        return dominant
    }
}

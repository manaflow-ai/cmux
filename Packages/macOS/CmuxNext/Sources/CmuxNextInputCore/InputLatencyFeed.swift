/// Where a reader gets closed input latency slots one by one, as they close: the Debug latency HUD
/// (CmuxNextFocusUI) reads it only while it is shown, so a closed HUD costs the producer no reader.
///
/// ``InputLatencySlotFeed`` is the producer: the input latency tracker, which closes slots on the
/// main thread, hands it each one, and the feed calls each reader in that turn, with no hop.
/// Chrome's `EventLatency` tracing works the same way: the per-event breakdown is only emitted
/// while a trace category is enabled (cc/metrics/compositor_frame_reporter.cc).
@MainActor
public protocol InputLatencyFeed: AnyObject {
    /// Adds a reader. It hears the newest `count` slots already closed (oldest of them first)
    /// before this returns, then each new slot in the turn it closes, until ``removeReader(_:)``.
    ///
    /// - Parameters:
    ///   - count: How many already closed slots to replay.
    ///   - read: Called on the main thread with each slot.
    /// - Returns: The reader, for ``removeReader(_:)``.
    func addReader(replaying count: Int, _ read: @escaping @MainActor (InputLatencySlot) -> Void) -> InputLatencyReader

    /// Stops calling `reader`; a reader already removed is ignored.
    func removeReader(_ reader: InputLatencyReader)
}

/// One reader of an ``InputLatencyFeed``.
public struct InputLatencyReader: Hashable, Sendable {
    /// The feed's number for the reader.
    public let id: UInt64

    public init(id: UInt64) {
        self.id = id
    }
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
    /// The longest of the intervals ``InputLatencyLedger`` files under each stage
    /// (``InputLatencyLedger/interval(to:in:)``), or nil when the input reached fewer than two
    /// stages. Of equal intervals, the one that ends at the earlier declared stage wins.
    public var dominantStage: InputLatencyDominantStage? {
        var dominant: InputLatencyDominantStage?
        for stage in InputLatencyLedger.pipelineStages where stage != .generated {
            guard let interval = InputLatencyLedger.interval(to: stage, in: self) else { continue }
            if dominant.map({ interval.nanos > $0.nanos }) ?? true {
                dominant = InputLatencyDominantStage(from: interval.from, to: stage, nanos: interval.nanos)
            }
        }
        return dominant
    }
}

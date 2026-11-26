import Foundation

/// Deterministic bitrate adaptation from ack round-trip observations.
///
/// All time is passed in explicitly (seconds on any monotonic clock), so the
/// policy is exhaustively testable. The controller reacts to congestion
/// multiplicatively and probes upward slowly:
/// - an ack that arrives later than `congestedAckDelay` after its frame was
///   sent cuts the target by `decreaseFactor` (at most once per `holdOff`),
/// - a sustained run of acks faster than `promptAckDelay` raises the target
///   by `increaseFactor` (also rate-limited by `holdOff`).
public struct SimStreamBitrateController: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        public var initialBitsPerSecond: Int
        public var minimumBitsPerSecond: Int
        public var maximumBitsPerSecond: Int
        /// Ack delay treated as congestion.
        public var congestedAckDelay: TimeInterval
        /// Ack delay treated as headroom.
        public var promptAckDelay: TimeInterval
        /// Consecutive prompt acks required before probing upward.
        public var promptAckRunLength: Int
        /// Minimum spacing between target changes.
        public var holdOff: TimeInterval
        public var decreaseFactor: Double
        public var increaseFactor: Double

        public init(
            initialBitsPerSecond: Int = 8_000_000,
            minimumBitsPerSecond: Int = 600_000,
            maximumBitsPerSecond: Int = 20_000_000,
            congestedAckDelay: TimeInterval = 0.25,
            promptAckDelay: TimeInterval = 0.08,
            promptAckRunLength: Int = 30,
            holdOff: TimeInterval = 1.0,
            decreaseFactor: Double = 0.65,
            increaseFactor: Double = 1.25
        ) {
            self.initialBitsPerSecond = initialBitsPerSecond
            self.minimumBitsPerSecond = minimumBitsPerSecond
            self.maximumBitsPerSecond = maximumBitsPerSecond
            self.congestedAckDelay = congestedAckDelay
            self.promptAckDelay = promptAckDelay
            self.promptAckRunLength = promptAckRunLength
            self.holdOff = holdOff
            self.decreaseFactor = decreaseFactor
            self.increaseFactor = increaseFactor
        }
    }

    public let configuration: Configuration
    public private(set) var targetBitsPerSecond: Int
    private var lastChangeTime: TimeInterval?
    private var promptAckRun: Int = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.targetBitsPerSecond = configuration.initialBitsPerSecond
    }

    /// Records that the frame with `sendTime` was acknowledged at `ackTime`.
    /// Returns the new target when it changed, nil otherwise.
    public mutating func recordAck(
        sendTime: TimeInterval, ackTime: TimeInterval
    ) -> Int? {
        let delay = ackTime - sendTime
        if delay >= configuration.congestedAckDelay {
            promptAckRun = 0
            return changeTarget(
                to: Double(targetBitsPerSecond) * configuration.decreaseFactor,
                at: ackTime
            )
        }
        if delay <= configuration.promptAckDelay {
            promptAckRun += 1
            if promptAckRun >= configuration.promptAckRunLength {
                let changed = changeTarget(
                    to: Double(targetBitsPerSecond) * configuration.increaseFactor,
                    at: ackTime
                )
                if changed != nil { promptAckRun = 0 }
                return changed
            }
        } else {
            promptAckRun = 0
        }
        return nil
    }

    private mutating func changeTarget(
        to proposal: Double, at time: TimeInterval
    ) -> Int? {
        if let last = lastChangeTime, time - last < configuration.holdOff {
            return nil
        }
        let clamped = min(
            max(Int(proposal), configuration.minimumBitsPerSecond),
            configuration.maximumBitsPerSecond
        )
        guard clamped != targetBitsPerSecond else { return nil }
        targetBitsPerSecond = clamped
        lastChangeTime = time
        return clamped
    }
}

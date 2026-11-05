import Foundation

/// A download's time left, from the byte counts as they arrive (Leo 2026-11-05: "can we have,
/// like, a better-looking update downloading thing?"). The speed is the bytes over the last few seconds,
/// so one slow or bursty report does not swing it; the time left is rounded to a step that grows with it
/// (5 s under a minute, whole minutes above), so the line changes rarely and calmly. Nothing shows until
/// a second of samples is in.
nonisolated public struct UpdateTransferRate: Equatable, Sendable {
    /// One byte count and when it arrived.
    struct Sample: Equatable {
        var bytes: UInt64
        var at: Date
    }

    /// The samples of the last ``window``, oldest first.
    private(set) var samples: [Sample] = []
    /// How far back the speed looks.
    static let window: TimeInterval = 5
    /// The span of samples the first estimate waits for.
    static let settle: TimeInterval = 1

    public init() {}

    /// Takes `phase`'s byte count at `now`; any other phase (or a count that went back: a new download)
    /// starts over.
    public mutating func record(_ phase: UpdateIndicatorPhase, at now: Date) {
        guard case .downloading(let transfer) = phase, transfer.stage == .downloading, let bytes = transfer.receivedBytes else {
            samples.removeAll()
            return
        }
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }
        if samples.last?.bytes == bytes { return }
        samples.append(Sample(bytes: bytes, at: now))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.window }
    }

    /// Bytes per second over the window, nil until it spans ``settle``.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= Self.settle, last.bytes > first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / span
    }

    /// Seconds until `expected` bytes are in at the current speed, rounded up to 5 s under a minute and to
    /// whole minutes above; nil without a speed or a size.
    public func secondsLeft(expected: UInt64?) -> Int? {
        guard let rate = bytesPerSecond, rate > 0, let expected, let last = samples.last, expected > last.bytes else { return nil }
        let seconds = Double(expected - last.bytes) / rate
        let step: Double = seconds < 60 ? 5 : 60
        return Int((seconds / step).rounded(.up) * step)
    }

    /// The card's second line, "About 15 s left", or nil while unmeasured. The time left alone: the
    /// line above already counts the bytes, and a speed would swing with every report.
    public func text(expected: UInt64?) -> String? {
        guard let left = secondsLeft(expected: expected) else { return nil }
        return left < 60 ? UpdaterStrings.secondsLeft(left) : UpdaterStrings.minutesLeft(left / 60)
    }
}

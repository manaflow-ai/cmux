import Foundation

/// Whether the path counts as high latency, with hysteresis: one RTT sample over the interactive
/// limit flipped the pane to view only and showed "View only: high latency", and the next sample
/// under it took that back. The path now has to stay over the limit for ``sustain`` before it counts
/// as high, and under it for ``sustain`` before it counts as low again. Pure: the caller passes the
/// time of each sample (``RemotePaneReducer``) and re-checks at ``due`` when no sample comes.
public nonisolated struct RemoteLatencyHold: Sendable, Hashable {
    /// How long the path must stay on the other side of the limit before the state flips.
    public static let sustain: Duration = .seconds(3)

    /// The held state: true while the path counts as high latency.
    public private(set) var high = false
    /// When the samples began to disagree with ``high``; nil while they agree.
    public private(set) var crossedAt: ContinuousClock.Instant?

    public init() {}

    /// When a pending flip is due, if the samples keep disagreeing; nil with none pending.
    public var due: ContinuousClock.Instant? { crossedAt.map { $0 + Self.sustain } }

    /// Takes a sample (`over`: the RTT is above the limit) at `now`, or re-checks the last one.
    public mutating func sample(over: Bool, at now: ContinuousClock.Instant) {
        guard over != high else {
            crossedAt = nil
            return
        }
        let since = crossedAt ?? now
        if now - since >= Self.sustain {
            high = over
            crossedAt = nil
        } else {
            crossedAt = since
        }
    }

    /// A new session: no measured path yet, so not high.
    public mutating func reset() {
        high = false
        crossedAt = nil
    }
}

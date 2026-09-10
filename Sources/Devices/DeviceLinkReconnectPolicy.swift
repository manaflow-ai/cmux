import Foundation

/// The reconnect state machine for one device link, as a pure reducer so the
/// recovery contract (network blip, remote app restart, presence flip, sign-out)
/// is unit-testable without a transport.
///
/// Signals, not timers, drive it: presence edges from the directory, the
/// transport closing, an RPC failing, and an explicit refresh. The only timer is
/// the bounded backoff `waiting` names, which the owner sleeps on and then feeds
/// back as `.waitElapsed`.
struct DeviceLinkReconnectPolicy: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Nothing to do: the device is offline, undialable, or the link is stopped.
        case idle
        case connecting(attempt: Int)
        case connected
        /// Backing off after `attempt` failures; reconnect once `delay` elapses.
        case waiting(attempt: Int, delay: Duration)
        /// A non-retryable failure (another account, unsupported routes); a
        /// presence or route change is the only way out.
        case blocked(reason: String)
    }

    enum Event: Equatable, Sendable {
        /// The directory's view of the device changed. `dialable` folds online,
        /// routes, and account trust.
        case directory(dialable: Bool)
        case connectSucceeded
        case connectFailed(retryable: Bool, reason: String)
        /// The live transport closed or an RPC on it failed.
        case transportLost
        case waitElapsed
        case refreshRequested
        case stopped
    }

    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]

    static func delay(afterFailures failures: Int) -> Duration {
        delays[min(max(failures - 1, 0), delays.count - 1)]
    }

    private(set) var phase: Phase = .idle
    /// The directory's latest verdict, remembered so a wait can re-check it.
    private(set) var isDialable = false
    private var connectedSince: Date?
    private var shortLivedLosses = 0
    static let stableConnectionInterval: TimeInterval = 30

    mutating func apply(_ event: Event, now: Date = .distantPast) -> Phase {
        switch event {
        case .stopped:
            phase = .idle
            connectedSince = nil
            shortLivedLosses = 0
        case .directory(let dialable):
            isDialable = dialable
            if !dialable {
                phase = .idle
                connectedSince = nil
                shortLivedLosses = 0
            } else {
                switch phase {
                case .idle, .blocked:
                    phase = .connecting(attempt: 1)
                case .connecting, .connected, .waiting:
                    break
                }
            }
        case .connectSucceeded:
            if case .connecting = phase {
                phase = .connected
                connectedSince = now
            }
        case .connectFailed(let retryable, let reason):
            guard case .connecting(let attempt) = phase else { return phase }
            guard isDialable else { phase = .idle; return phase }
            phase = retryable
                ? .waiting(attempt: attempt, delay: Self.delay(afterFailures: attempt))
                : .blocked(reason: reason)
        case .transportLost:
            guard phase == .connected else { return phase }
            guard isDialable else { phase = .idle; return phase }
            if let connectedSince, now.timeIntervalSince(connectedSince) >= Self.stableConnectionInterval {
                shortLivedLosses = 0
            }
            connectedSince = nil
            shortLivedLosses += 1
            if shortLivedLosses == 1 {
                phase = .connecting(attempt: 1)
            } else {
                let failures = shortLivedLosses - 1
                phase = .waiting(attempt: failures, delay: Self.delay(afterFailures: failures))
            }
        case .waitElapsed:
            guard case .waiting(let attempt, _) = phase else { return phase }
            phase = isDialable ? .connecting(attempt: attempt + 1) : .idle
        case .refreshRequested:
            guard isDialable else { phase = .idle; return phase }
            switch phase {
            case .idle, .waiting, .blocked:
                shortLivedLosses = 0
                phase = .connecting(attempt: 1)
            case .connecting, .connected:
                break
            }
        }
        return phase
    }
}

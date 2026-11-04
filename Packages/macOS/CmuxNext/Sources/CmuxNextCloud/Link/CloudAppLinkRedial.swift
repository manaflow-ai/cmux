public import CmuxNextWakeups

/// Dials a Cloud machine's app link again after it dropped, instead of waiting for a click (hq#7060: a new
/// machine's receiver answered 31 s after boot, after the app's two connects had ended, and nothing dialed again).
/// Redials are spaced by a capped backoff and bounded: past `tries` ends in a row the link waits for a click, as
/// before. A drop after a connection that stayed up `healthy` starts the count over, so a link that drops now and
/// then redials every time, while one that ends at every handshake gives up after its tries.
@MainActor
public final class CloudAppLinkRedial {
    private let policy: Backoff
    private var backoff: Backoff
    private let tries: Int
    private let healthy: Duration
    private let clock = ContinuousClock()
    /// Ends since the count last started over; the next redial is the `ends`th.
    public private(set) var ends = 0
    private var upSince: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?

    public init(backoff: Backoff = Backoff(initial: .seconds(1), maximum: .seconds(30)), tries: Int = 6, healthy: Duration = .seconds(30)) {
        policy = backoff
        self.backoff = backoff
        self.tries = tries
        self.healthy = healthy
    }

    /// The last end is one a redial can help (``CloudLinkError/isRedialable(_:)``), or any end but a revoke once redials
    /// started: a start's wait and the scheduled redial dial only such an end.
    public private(set) var lastEndRedialable = false

    /// A redial is waiting out its delay.
    public var isPending: Bool { pending != nil }

    /// The link's daemon connection came up (its handshake passed).
    public func up() { upSince = clock.now }

    /// The link ended with `error`: schedules `redial` after the next delay and returns true, or returns false when no
    /// redial follows. Only a `live` machine's link (running, not removed) redials, and `read` (a forced read of the
    /// machine's record) runs before each: the idle auto-pause may have parked the machine behind the app, and a
    /// connect to a parked machine would start it. An end a redial can help
    /// (``CloudLinkError/isRedialable(_:)``) starts the redials; once they started, any end but a revoke goes on with
    /// them (a redial's connect can fail while the machine still comes up). A revoke is the server's answer, never
    /// redialed. Past `tries` ends in a row none follows until a click or a healthy connection.
    @discardableResult
    public func ended(_ error: any Error, live: Bool = true, read: (@MainActor (_ force: Bool) async -> Void)? = nil,
                      redial: @escaping @MainActor () -> Void) -> Bool {
        if let upSince, upSince.duration(to: clock.now) >= healthy { startOver() }
        upSince = nil
        let revoked = if case CloudLinkError.revoked = error { true } else { false }
        lastEndRedialable = CloudLinkError.isRedialable(error) || (ends > 0 && !revoked)
        guard live, lastEndRedialable else {
            cancel()
            return false
        }
        // Spent: the link waits for a click (``cancel()``) or a healthy connection to start over.
        guard ends < tries else { return false }
        ends += 1
        let delay = backoff.next()
        pending?.cancel()
        // task-owner: one delayed redial; a later end, a click, a pause or a disconnect cancels it
        pending = Task { [weak self] in
            // wakeup-allow: one backoff delay before a bounded redial of a dropped link
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await read?(true)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            redial()
        }
        return true
    }

    /// A click, a pause or a disconnect: no redial is pending and the count starts over.
    public func cancel() {
        pending?.cancel()
        pending = nil
        upSince = nil
        startOver()
    }

    private func startOver() {
        ends = 0
        backoff = policy
    }
}

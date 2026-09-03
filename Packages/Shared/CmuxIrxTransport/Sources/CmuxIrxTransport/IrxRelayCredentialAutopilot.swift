public import Foundation

/// Keeps the endpoint's relay credentials perpetually fresh: mints early
/// (min(refreshAfter, expiry-120s) minus jitter), rotates with insertRelay
/// alone (make-before-break), and on mint failure retries at half the
/// remaining validity so retries speed up toward expiry instead of backing
/// off past it. The relay closes connections at the signed expiry, so this
/// loop is what makes 15 minutes without a disconnect possible at all. With
/// nothing cached there is no expiry to race, so failures back off
/// exponentially and honor the broker's `Retry-After`.
public actor IrxRelayCredentialAutopilot {
    /// Waits out a computed delay. Injected so the retry ladder is testable
    /// without wall-clock time; cancellation propagates through it, and the
    /// loop's own `Task.isCancelled` checks bound every wait.
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let broker: IrxBrokerService
    private let endpoint: IrxEndpointSupervisor
    private let journal: IrxJournal
    private let sleep: Sleeper
    private var loop: Task<Void, Never>?
    /// Runs after every successful rotation. Hosts re-register here so their
    /// advertised relay hint (server-capped at a 1h lifetime) never expires.
    public var onRotation: (@Sendable () async -> Void)?

    public init(
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor,
        journal: IrxJournal,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.broker = broker
        self.endpoint = endpoint
        self.journal = journal
        self.sleep = sleep
    }

    public func setOnRotation(_ handler: @escaping @Sendable () async -> Void) {
        onRotation = handler
    }

    /// Usable credentials for binding/dialing RIGHT NOW: cached when fresh
    /// (zero broker calls on the fast path), minted when the cache is empty
    /// or stale.
    public func usableCredentials() async throws -> [IrxRelayCredential] {
        let cached = await broker.cachedRelayCredentials()
        if !cached.isEmpty {
            return cached
        }
        return try await broker.mintRelayCredentials()
    }

    /// Starts the refresh loop. Idempotent; cancelled by `stop()`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
        journal.record("credential-autopilot", "started")
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        journal.record("credential-autopilot", "stopped")
    }

    /// Foreground/resume kick: restart the loop so a suspension can never
    /// leave a stale sleep deadline in charge of renewal.
    public func kick() {
        loop?.cancel()
        loop = Task { await self.run() }
        journal.record("credential-autopilot", "kicked")
    }

    private func run() async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            let now = Date()
            let credentials = await broker.cachedRelayCredentials()
            if let soonest = credentials.map({
                IrxRelayCredentialPolicy.refreshDate(
                    for: $0, jitter: Double.random(in: 0...10))
            }).min(), soonest > now {
                let wait = soonest.timeIntervalSince(now)
                journal.record(
                    "credential-autopilot", "sleeping",
                    ["until_refresh_s": String(Int(wait))]
                )
                try? await sleep(.seconds(wait))
                if Task.isCancelled { return }
            }
            do {
                let minted = try await broker.mintRelayCredentials()
                await endpoint.rotateCredentials(minted)
                await onRotation?()
                consecutiveFailures = 0
            } catch {
                consecutiveFailures += 1
                // `nil`, not `Date()`: with nothing cached there is no expiry
                // to race, and passing the current time collapsed the delay to
                // a one-second loop that never backed off.
                let expiry = credentials.map(\.expiresAt).max()
                let retryAfter = IrxRelayCredentialPolicy.retryAfterSeconds(for: error)
                let delay = IrxRelayCredentialPolicy.retryDelay(
                    expiresAt: expiry,
                    now: Date(),
                    consecutiveFailures: consecutiveFailures,
                    retryAfterSeconds: retryAfter
                )
                journal.record(
                    "credential-autopilot", "mint-failed",
                    [
                        "error": String(describing: error),
                        "failures": String(consecutiveFailures),
                        "retry_after_s": retryAfter.map(String.init) ?? "none",
                        "retry": String(describing: delay),
                    ]
                )
                try? await sleep(delay)
            }
        }
    }
}

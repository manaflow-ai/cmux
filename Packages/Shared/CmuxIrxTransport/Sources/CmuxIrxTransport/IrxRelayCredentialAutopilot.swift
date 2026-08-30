import Foundation
public import CmuxIrohTransport

/// Keeps the endpoint's relay credentials perpetually fresh: mints early
/// (min(refreshAfter, expiry-120s) minus jitter), rotates with insertRelay
/// alone (make-before-break), and on mint failure retries at half the
/// remaining validity so retries speed up toward expiry instead of backing
/// off past it. The relay closes connections at the signed expiry, so this
/// loop is what makes 15 minutes without a disconnect possible at all.
public actor IrxRelayCredentialAutopilot {
    private let broker: IrxBrokerService
    private let endpoint: IrxEndpointSupervisor
    private let journal: IrxJournal
    private let clock: any CmxIrohRelayClock
    private var loop: Task<Void, Never>?
    /// Runs after every successful rotation. Hosts re-register here so their
    /// advertised relay hint (server-capped at a 1h lifetime) never expires.
    public var onRotation: (@Sendable () async throws -> Void)?
    /// Reports a classified broker failure to the lifecycle owner. The owner
    /// decides whether an auth rejection tears down the endpoint or a transient
    /// failure remains on the bounded refresh ladder.
    public var onFailure: (@Sendable (IrxBrokerFailure) async -> Void)?

    public init(
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor,
        journal: IrxJournal,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock()
    ) {
        self.broker = broker
        self.endpoint = endpoint
        self.journal = journal
        self.clock = clock
    }

    public func setOnRotation(_ handler: @escaping @Sendable () async throws -> Void) {
        onRotation = handler
    }

    /// Installs the lifecycle failure sink for mint and hint-refresh errors.
    public func setOnFailure(_ handler: @escaping @Sendable (IrxBrokerFailure) async -> Void) {
        onFailure = handler
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
        var failureCount = 0
        var bypassRefreshDeadlineOnce = false
        while !Task.isCancelled {
            let now = Date()
            let credentials = await broker.cachedRelayCredentials()
            if !bypassRefreshDeadlineOnce, let soonest = credentials.map({
                IrxRelayCredentialPolicy.refreshDate(
                    for: $0, jitter: Double.random(in: 0...10))
            }).min(), soonest > now {
                let wait = soonest.timeIntervalSince(now)
                journal.record(
                    "credential-autopilot", "sleeping",
                    ["until_refresh_s": String(Int(wait))]
                )
                try? await clock.sleep(
                    until: clock.now().addingTimeInterval(wait)
                )
                if Task.isCancelled { return }
            }
            bypassRefreshDeadlineOnce = false
            do {
                let minted = try await broker.mintRelayCredentials()
                await endpoint.rotateCredentials(minted)
                try await onRotation?()
                failureCount = 0
            } catch {
                let failure = error as? IrxBrokerFailure
                    ?? IrxBrokerFailure(operation: .mint, error: error)
                let expiry = credentials.map(\.expiresAt).max()
                let decision = IrxHostActivationPolicy().decision(
                    for: failure,
                    failureCount: failureCount,
                    jitterUnitInterval: Double.random(in: 0 ... 1)
                )
                if case .reauthenticationRequired = decision {
                    journal.record(
                        "credential-autopilot", "mint-failed", failure.journalAttributes)
                    await onFailure?(failure)
                    return
                }
                if case .stopped = decision {
                    journal.record(
                        "credential-autopilot", "mint-stopped", failure.journalAttributes)
                    await onFailure?(failure)
                    return
                }
                let policyDelay: TimeInterval
                switch decision {
                case let .retry(delay, _): policyDelay = delay
                case .stopped, .reauthenticationRequired: policyDelay = 1
                }
                let expiryDelay = expiry.flatMap { expiryDate -> TimeInterval? in
                    guard expiryDate.timeIntervalSinceNow > 2 else { return nil }
                    return Self.seconds(from: IrxRelayCredentialPolicy.retryDelay(
                        expiresAt: expiryDate,
                        now: Date()
                    ))
                }
                let delaySeconds = min(expiryDelay ?? policyDelay, policyDelay)
                var failureAttributes = failure.journalAttributes
                failureAttributes["retry_delay_s"] = String(Int(delaySeconds.rounded()))
                failureAttributes["failure_count"] = String(failureCount)
                journal.record(
                    "credential-autopilot", "mint-failed",
                    failureAttributes
                )
                await onFailure?(failure)
                failureCount = min(failureCount + 1, 20)
                bypassRefreshDeadlineOnce = true
                try? await clock.sleep(
                    until: clock.now().addingTimeInterval(delaySeconds)
                )
            }
        }
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

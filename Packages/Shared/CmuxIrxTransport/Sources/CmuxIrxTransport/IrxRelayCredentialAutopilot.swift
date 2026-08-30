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
    /// leave a stale sleep deadline in charge of renewal. Pass `immediately`
    /// only when the caller has a known pending rotation that must run now;
    /// ordinary foregrounding re-evaluates credential freshness first.
    public func kick(immediately: Bool = false) {
        loop?.cancel()
        loop = Task { await self.run(bypassRefreshDeadlineOnce: immediately) }
        journal.record("credential-autopilot", "kicked")
    }

    private func run(bypassRefreshDeadlineOnce: Bool = false) async {
        var bypassRefreshDeadlineOnce = bypassRefreshDeadlineOnce
        var failureCount = 0
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
                guard !Task.isCancelled else { return }
                await endpoint.rotateCredentials(minted)
                guard !Task.isCancelled else { return }
                guard await refreshHint(initialFailureCount: 0) else { return }
                failureCount = 0
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? IrxBrokerFailure
                    ?? IrxBrokerFailure(
                        operation: .mint,
                        error: error,
                        fallbackKind: .transient
                    )
                let expiry = credentials.map(\.expiresAt).max()
                guard let nextFailureCount = await waitForRetry(
                    after: failure,
                    failureCount: failureCount,
                    credentialExpiry: expiry
                ) else { return }
                failureCount = nextFailureCount
                bypassRefreshDeadlineOnce = true
            }
        }
    }

    /// Retries a failed hint registration without minting another credential.
    /// A hint outage must not turn a healthy credential into a mint loop.
    private func refreshHint(initialFailureCount: Int) async -> Bool {
        var failureCount = initialFailureCount
        while !Task.isCancelled {
            do {
                try await onRotation?()
                return !Task.isCancelled
            } catch is CancellationError {
                return false
            } catch {
                guard !Task.isCancelled else { return false }
                let failure = error as? IrxBrokerFailure
                    ?? IrxBrokerFailure(
                        operation: .hintRefresh,
                        error: error,
                        fallbackKind: .transient
                    )
                guard let nextFailureCount = await waitForRetry(
                    after: failure,
                    failureCount: failureCount,
                    credentialExpiry: nil
                ) else { return false }
                failureCount = nextFailureCount
            }
        }
        return false
    }

    /// Journals one classified failure, notifies the lifecycle owner, and
    /// performs its cancellable bounded wait. `nil` means the owner chose a
    /// terminal state such as reauthentication or an explicit failure.
    private func waitForRetry(
        after failure: IrxBrokerFailure,
        failureCount: Int,
        credentialExpiry: Date?
    ) async -> Int? {
        let decision = IrxHostActivationPolicy().decision(
            for: failure,
            failureCount: failureCount,
            jitterUnitInterval: Double.random(in: 0 ... 1)
        )
        let event = failure.operation == .hintRefresh
            ? "hint-refresh-failed" : "mint-failed"
        switch decision {
        case .reauthenticationRequired:
            journal.record("credential-autopilot", event, failure.journalAttributes)
            await onFailure?(failure)
            return nil
        case .stopped:
            journal.record("credential-autopilot", "mint-stopped", failure.journalAttributes)
            await onFailure?(failure)
            return nil
        case let .retry(policyDelay, retryAfterSeconds):
            let delaySeconds = IrxRelayCredentialPolicy.boundedRetryDelay(
                expiresAt: credentialExpiry,
                now: Date(),
                policyDelay: policyDelay,
                retryAfterSeconds: retryAfterSeconds
            )
            var attributes = failure.journalAttributes
            attributes["retry_delay_s"] = String(Int(delaySeconds.rounded()))
            attributes["failure_count"] = String(failureCount)
            journal.record("credential-autopilot", event, attributes)
            await onFailure?(failure)
            guard !Task.isCancelled else { return nil }
            try? await clock.sleep(
                until: clock.now().addingTimeInterval(delaySeconds)
            )
            guard !Task.isCancelled else { return nil }
            return min(failureCount + 1, 20)
        }
    }

}

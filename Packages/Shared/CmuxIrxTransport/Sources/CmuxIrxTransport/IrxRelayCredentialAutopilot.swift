public import Foundation
public import CmuxIrohTransport

/// Keeps the endpoint's relay credentials perpetually fresh: mints early
/// (min(refreshAfter, expiry-120s) minus jitter), rotates with insertRelay
/// alone (make-before-break), and on mint failure retries at half the
/// remaining validity so retries speed up toward expiry instead of backing
/// off past it. The relay closes connections at the signed expiry, so this
/// loop is what makes 15 minutes without a disconnect possible at all.
public actor IrxRelayCredentialAutopilot {
    private static let maximumHintRetryAttempts = 3

    private enum HintRefreshOutcome: Equatable {
        case succeeded
        case exhausted
        case stopped
    }

    private struct FailureCounts: Sendable {
        var transient = 0
        var unauthorized = 0
    }

    /// The disposition the autopilot selected for a classified failure.
    /// Lifecycle owners must not re-derive this decision from a second counter.
    public enum FailureDisposition: Equatable, Sendable {
        /// The autopilot will sleep for the supplied delay before retrying.
        case retry(delay: TimeInterval)
        /// A non-fatal auxiliary operation failed; the endpoint remains live.
        case advisory
        /// The autopilot has stopped and requires lifecycle-owner action.
        /// The reason is carried so every platform applies the same outcome.
        case terminal(requiresReauthentication: Bool)
    }

    private let broker: IrxBrokerService
    private let endpoint: IrxEndpointSupervisor
    private let journal: IrxJournal
    private let clock: any CmxIrohRelayClock
    private let retryPolicy: IrxHostActivationPolicy
    private var loop: Task<Void, Never>?
    private var loopGeneration: UInt64 = 0
    /// Runs after every successful rotation. Hosts re-register here so their
    /// advertised relay hint (server-capped at a 1h lifetime) never expires.
    public var onRotation: (@Sendable () async throws -> Void)?
    /// Reports a classified broker failure and the disposition selected by this
    /// autopilot to the lifecycle owner. The disposition is authoritative so
    /// platform owners do not re-derive retry state with a second counter.
    public var onFailure: (@Sendable (IrxBrokerFailure, FailureDisposition) async -> Void)?

    public init(
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor,
        journal: IrxJournal,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        retryPolicy: IrxHostActivationPolicy = IrxHostActivationPolicy()
    ) {
        self.broker = broker
        self.endpoint = endpoint
        self.journal = journal
        self.clock = clock
        self.retryPolicy = retryPolicy
    }

    public func setOnRotation(_ handler: @escaping @Sendable () async throws -> Void) {
        onRotation = handler
    }

    /// Installs the lifecycle failure sink for mint and hint-refresh errors.
    /// Installs the lifecycle failure sink.
    public func setOnFailure(
        _ handler: @escaping @Sendable (IrxBrokerFailure, FailureDisposition) async -> Void
    ) {
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
        loopGeneration &+= 1
        let generation = loopGeneration
        loop = Task { await self.run(generation: generation) }
        journal.record("credential-autopilot", "started")
    }

    public func stop() {
        loopGeneration &+= 1
        loop?.cancel()
        loop = nil
        journal.record("credential-autopilot", "stopped")
    }

    /// Foreground/resume kick: restart the loop so a suspension can never
    /// leave a stale sleep deadline in charge of renewal. Credential freshness
    /// is re-evaluated before minting, so foregrounding does not churn tokens.
    public func kick() {
        loopGeneration &+= 1
        let generation = loopGeneration
        loop?.cancel()
        loop = Task { await self.run(generation: generation) }
        journal.record("credential-autopilot", "kicked")
    }

    /// Retries a known pending hint registration without minting a new relay
    /// credential. Used by a host immediately after deferred activation.
    public func kickHintRefresh() {
        loopGeneration &+= 1
        let generation = loopGeneration
        loop?.cancel()
        loop = Task {
            let outcome = await self.refreshHint(initialFailureCount: 0)
            guard outcome != .stopped else {
                self.clearLoopIfCurrent(generation: generation)
                return
            }
            guard !Task.isCancelled else { return }
            await self.run(generation: generation)
        }
        journal.record("credential-autopilot", "hint-refresh-kicked")
    }

    private func run(
        bypassRefreshDeadlineOnce: Bool = false,
        generation: UInt64
    ) async {
        defer { clearLoopIfCurrent(generation: generation) }
        var bypassRefreshDeadlineOnce = bypassRefreshDeadlineOnce
        var failureCounts = FailureCounts()
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
                guard await refreshHint(initialFailureCount: 0) != .stopped else { return }
                failureCounts = FailureCounts()
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
                    failureCount: failureCounts.transient,
                    unauthorizedFailureCount: failureCounts.unauthorized,
                    credentialExpiry: expiry
                ) else { return }
                failureCounts.transient = nextFailureCount.transient
                failureCounts.unauthorized = nextFailureCount.unauthorized
                bypassRefreshDeadlineOnce = true
            }
        }
    }

    private func clearLoopIfCurrent(generation: UInt64) {
        guard loopGeneration == generation else { return }
        loop = nil
    }

    /// Retries a failed hint registration without minting another credential.
    /// A hint outage must not turn a healthy credential into a mint loop.
    private func refreshHint(initialFailureCount: Int) async -> HintRefreshOutcome {
        var failureCount = initialFailureCount
        var unauthorizedFailureCount = 0
        for _ in 0 ..< Self.maximumHintRetryAttempts {
            guard !Task.isCancelled else { return .stopped }
            do {
                try await onRotation?()
                return Task.isCancelled ? .stopped : .succeeded
            } catch is CancellationError {
                return .stopped
            } catch {
                guard !Task.isCancelled else { return .stopped }
                let failure = error as? IrxBrokerFailure
                    ?? IrxBrokerFailure(
                        operation: .hintRefresh,
                        error: error,
                        fallbackKind: .transient
                    )
                if !failure.isRetryable {
                    if failure.requiresReauthentication {
                        await onFailure?(failure, .terminal(requiresReauthentication: true))
                        return .stopped
                    }
                    await onFailure?(failure, .advisory)
                    journal.record(
                        "credential-autopilot", "hint-refresh-rejected",
                        failure.journalAttributes
                    )
                    return .exhausted
                }
                guard let nextFailureCount = await waitForRetry(
                    after: failure,
                    failureCount: failureCount,
                    unauthorizedFailureCount: unauthorizedFailureCount,
                    credentialExpiry: nil,
                    escalateUnauthorized: false
                ) else { return .stopped }
                failureCount = nextFailureCount.transient
                unauthorizedFailureCount = nextFailureCount.unauthorized
            }
        }
        journal.record(
            "credential-autopilot", "hint-refresh-exhausted",
            ["attempts": String(Self.maximumHintRetryAttempts)]
        )
        return .exhausted
    }

    /// Journals one classified failure, notifies the lifecycle owner, and
    /// performs its cancellable bounded wait. `nil` means the owner chose a
    /// terminal state such as reauthentication or an explicit failure.
    private func waitForRetry(
        after failure: IrxBrokerFailure,
        failureCount: Int,
        unauthorizedFailureCount: Int,
        credentialExpiry: Date?,
        escalateUnauthorized: Bool = true
    ) async -> FailureCounts? {
        let isPostRecoveryUnauthorized = failure.statusCode == 401
            && !failure.requiresReauthentication
        let decision: IrxHostActivationPolicy.Decision
        if isPostRecoveryUnauthorized && !escalateUnauthorized {
            // The host callback owns the shared 401 escalation counter. The
            // autopilot's bounded hint burst must not independently terminate
            // credential renewal before that owner decides.
            decision = retryPolicy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: Double.random(in: 0 ... 1)
            )
        } else if isPostRecoveryUnauthorized {
            decision = retryPolicy.decision(
                for: failure,
                failureCount: unauthorizedFailureCount,
                jitterUnitInterval: Double.random(in: 0 ... 1)
            )
        } else {
            decision = retryPolicy.decision(
                for: failure,
                failureCount: failureCount,
                jitterUnitInterval: Double.random(in: 0 ... 1)
            )
        }
        let decisionFailureCount = isPostRecoveryUnauthorized
            ? unauthorizedFailureCount : failureCount
        let event = failure.operation == .hintRefresh
            ? "hint-refresh-failed" : "mint-failed"
        switch decision {
        case .reauthenticationRequired:
            journal.record("credential-autopilot", event, failure.journalAttributes)
            await onFailure?(failure, .terminal(requiresReauthentication: true))
            return nil
        case .stopped:
            journal.record("credential-autopilot", "mint-stopped", failure.journalAttributes)
            await onFailure?(failure, .terminal(requiresReauthentication: false))
            return nil
        case let .retry(policyDelay, retryAfterSeconds):
            let delaySeconds = IrxRelayCredentialPolicy.boundedRetryDelay(
                expiresAt: credentialExpiry,
                now: Date(),
                policyDelay: policyDelay,
                retryAfterSeconds: retryAfterSeconds,
                failureCount: decisionFailureCount
            )
            var attributes = failure.journalAttributes
            attributes["retry_delay_s"] = String(Int(delaySeconds.rounded()))
            attributes["failure_count"] = String(decisionFailureCount)
            journal.record("credential-autopilot", event, attributes)
            await onFailure?(failure, .retry(delay: delaySeconds))
            guard !Task.isCancelled else { return nil }
            try? await clock.sleep(
                until: clock.now().addingTimeInterval(delaySeconds)
            )
            guard !Task.isCancelled else { return nil }
            return FailureCounts(
                transient: isPostRecoveryUnauthorized
                    ? failureCount : min(failureCount + 1, 20),
                unauthorized: isPostRecoveryUnauthorized
                    ? min(unauthorizedFailureCount + 1, 20) : 0
            )
        }
    }

}

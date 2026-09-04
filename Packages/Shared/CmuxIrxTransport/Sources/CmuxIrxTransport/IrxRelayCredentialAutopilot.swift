import Foundation
public import CmuxIrohTransport

/// Keeps the endpoint's relay credentials perpetually fresh: mints early
/// (min(refreshAfter, expiry-120s) minus jitter), rotates with insertRelay
/// alone (make-before-break), and on mint failure retries at half the
/// remaining validity so retries speed up toward expiry instead of backing
/// off past it. The relay closes connections at the signed expiry, so this
/// loop is what makes 15 minutes without a disconnect possible at all.
public actor IrxRelayCredentialAutopilot {
    private static let maximumHintRetryAttempts = 3
    private static let hintRetrySchedule = CmxIrohRetrySchedule(
        initialDelay: 5,
        maximumDelay: 60,
        jitterFraction: 0.25
    )

    private typealias HintRefreshOutcome = IrxRelayCredentialAutopilotHintRefreshOutcome
    private typealias FailureCounts = IrxRelayCredentialAutopilotFailureCounts

    /// The disposition the autopilot selected for a classified failure.
    /// Lifecycle owners must not re-derive this decision from a second counter.
    public typealias FailureDisposition = IrxRelayCredentialAutopilotFailureDisposition

    private let broker: IrxBrokerService
    private let endpoint: IrxEndpointSupervisor
    private let journal: IrxJournal
    private let clock: any CmxIrohRelayClock
    private let retryPolicy: IrxHostActivationPolicy
    private let credentialPolicy = IrxRelayCredentialPolicy()
    private var loop: Task<Void, Never>?
    private var loopGeneration: UInt64 = 0
    /// Independent hint recovery never waits for the next credential mint.
    private var hintRetryTask: Task<Void, Never>?
    private var hintRetryID: UUID?
    private var hintRetryGeneration: UInt64 = 0
    private var hintRetryFailureCount = 0
    /// Runs after every successful rotation. Hosts re-register here so their
    /// advertised relay hint (server-capped at a 1h lifetime) never expires.
    public var onRotation: (@Sendable () async throws -> Void)?
    /// Reports a completed credential mint and endpoint rotation. This is
    /// deliberately separate from ``onRotation``: hint-only refreshes must not
    /// clear a lifecycle failure or mark an endpoint healthy.
    public var onCredentialRotation: (@Sendable () async -> Void)?
    /// Reports a classified broker failure and the disposition selected by this
    /// autopilot to the lifecycle owner. The disposition is authoritative so
    /// platform owners do not re-derive retry state with a second counter.
    public var onFailure: (@Sendable (IrxBrokerFailure, FailureDisposition) async -> Void)?

    /// Creates an autopilot with injected broker, endpoint, clock, and retry policy.
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

    /// Installs the callback used to publish a fresh relay hint after rotation.
    public func setOnRotation(_ handler: @escaping @Sendable () async throws -> Void) {
        onRotation = handler
    }

    /// Installs the callback invoked after credentials are rotated successfully.
    public func setOnCredentialRotation(_ handler: @escaping @Sendable () async -> Void) {
        onCredentialRotation = handler
    }

    /// Installs the lifecycle failure sink for mint and hint-refresh errors.
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

    /// Stops the refresh loop and cancels any in-flight wait.
    public func stop() {
        loopGeneration &+= 1
        loop?.cancel()
        loop = nil
        cancelHintRetry()
        journal.record("credential-autopilot", "stopped")
    }

    /// Foreground/resume kick: restart the loop so a suspension can never
    /// leave a stale sleep deadline in charge of renewal. Credential freshness
    /// is re-evaluated before minting, so foregrounding does not churn tokens.
    public func kick() {
        loopGeneration &+= 1
        let generation = loopGeneration
        loop?.cancel()
        cancelHintRetry()
        loop = Task { await self.run(generation: generation) }
        journal.record("credential-autopilot", "kicked")
    }

    /// Retries a known pending hint registration without minting a new relay
    /// credential. Used by a host immediately after deferred activation.
    public func kickHintRefresh() {
        // A foreground/deferred kick supersedes any scheduled hint retry. Reset
        // its generation and ladder before starting so an old task cannot
        // publish after this probe or bias its backoff.
        cancelHintRetry()
        loopGeneration &+= 1
        let generation = loopGeneration
        loop?.cancel()
        loop = Task {
            defer { self.clearLoopIfCurrent(generation: generation) }
            let outcome = await self.refreshHint()
            if outcome == .succeeded {
                self.cancelHintRetry()
            } else if outcome == .exhausted {
                self.scheduleHintRetry()
            }
            guard outcome != .stopped else { return }
            guard !Task.isCancelled else { return }
            // The outer kick task owns the `loop` handle; the nested run must
            // not clear it while this task is still executing.
            await self.run(generation: generation, clearsLoop: false)
        }
        journal.record("credential-autopilot", "hint-refresh-kicked")
    }

    private func run(
        bypassRefreshDeadlineOnce: Bool = false,
        generation: UInt64,
        clearsLoop: Bool = true
    ) async {
        defer {
            if clearsLoop {
                clearLoopIfCurrent(generation: generation)
            }
        }
        var bypassRefreshDeadlineOnce = bypassRefreshDeadlineOnce
        var failureCounts = FailureCounts()
        while !Task.isCancelled {
            let now = Date()
            let credentials = await broker.cachedRelayCredentials()
            if !bypassRefreshDeadlineOnce, let soonest = credentials.map({
                credentialPolicy.refreshDate(
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
                await onCredentialRotation?()
                let hintOutcome = await refreshHint()
                if hintOutcome == .exhausted {
                    scheduleHintRetry()
                } else if hintOutcome == .succeeded {
                    cancelHintRetry()
                }
                guard hintOutcome != .stopped else { return }
                failureCounts = FailureCounts()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? IrxBrokerFailure
                    ?? IrxBrokerFailure(
                        operation: .mint,
                        error: error,
                        fallbackKind: .invalid
                    )
                let expiry = credentials.map(\.expiresAt).max()
                guard let nextFailureCount = await waitForRetry(
                    after: failure,
                    failureCount: failureCounts.transient,
                    unauthorizedFailureCount: failureCounts.unauthorized,
                    missingAuthenticationFailureCount:
                        failureCounts.missingAuthentication,
                    credentialExpiry: expiry
                ) else { return }
                failureCounts.transient = nextFailureCount.transient
                failureCounts.unauthorized = nextFailureCount.unauthorized
                failureCounts.missingAuthentication = nextFailureCount.missingAuthentication
                bypassRefreshDeadlineOnce = true
            }
        }
    }

    private func clearLoopIfCurrent(generation: UInt64) {
        guard loopGeneration == generation else { return }
        loop = nil
    }

    /// Arms one bounded-delay hint probe without minting credentials again.
    /// Repeated outages advance a capped ladder, while a successful hint or a
    /// stopped autopilot cancels the independent task.
    private func scheduleHintRetry() {
        guard hintRetryTask == nil, !Task.isCancelled else { return }
        let generation = hintRetryGeneration
        let delay = Self.hintRetrySchedule.delay(
            failureCount: hintRetryFailureCount,
            retryAfterSeconds: nil,
            jitterUnitInterval: Double.random(in: 0 ... 1)
        )
        hintRetryFailureCount = min(hintRetryFailureCount + 1, 20)
        let deadline = clock.now().addingTimeInterval(delay)
        let retryID = UUID()
        hintRetryID = retryID
        journal.record(
            "credential-autopilot", "hint-retry-scheduled",
            ["retry_delay_s": String(Int(delay.rounded()))]
        )
        hintRetryTask = Task {
            defer {
                self.clearHintRetryIfCurrent(id: retryID, generation: generation)
            }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.hintRetryGeneration == generation,
                  self.hintRetryID == retryID else { return }
            let outcome = await self.refreshHint()
            guard self.hintRetryGeneration == generation,
                  self.hintRetryID == retryID else { return }
            self.hintRetryTask = nil
            self.hintRetryID = nil
            switch outcome {
            case .succeeded:
                self.hintRetryFailureCount = 0
            case .stopped:
                return
            case .exhausted:
                self.scheduleHintRetry()
            case .rejected:
                return
            }
        }
    }

    private func cancelHintRetry() {
        hintRetryGeneration &+= 1
        hintRetryTask?.cancel()
        hintRetryTask = nil
        hintRetryID = nil
        hintRetryFailureCount = 0
    }

    private func clearHintRetryIfCurrent(id: UUID, generation: UInt64) {
        guard hintRetryID == id, hintRetryGeneration == generation else { return }
        hintRetryTask = nil
        hintRetryID = nil
    }

    /// Retries a failed hint registration without minting another credential.
    /// A hint outage must not turn a healthy credential into a mint loop.
    private func refreshHint() async -> HintRefreshOutcome {
        // Each invocation is one bounded, caller-requested hint probe. The
        // ladder is local to that probe; the caller's next kick is a fresh
        // observation rather than a continuation of stale work.
        var failureCount = 0
        var unauthorizedFailureCount = 0
        var missingAuthenticationFailureCount = 0
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
                        fallbackKind: .invalid
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
                    return .rejected
                }
                guard let nextFailureCount = await waitForRetry(
                    after: failure,
                    failureCount: failureCount,
                    unauthorizedFailureCount: unauthorizedFailureCount,
                    missingAuthenticationFailureCount: missingAuthenticationFailureCount,
                    credentialExpiry: nil,
                    escalateUnauthorized: false
                ) else { return .stopped }
                failureCount = nextFailureCount.transient
                unauthorizedFailureCount = nextFailureCount.unauthorized
                missingAuthenticationFailureCount = nextFailureCount.missingAuthentication
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
        missingAuthenticationFailureCount: Int,
        credentialExpiry: Date?,
        escalateUnauthorized: Bool = true
    ) async -> FailureCounts? {
        let escalationBucket = failure.escalationBucket
        // Select one cause-specific count and feed it to both the policy and
        // the bounded-delay/journal path. Auxiliary hint retries suppress only
        // terminal auth escalation; they still use their local count.
        let decisionFailureCount: Int = switch escalationBucket {
        case .unauthorized:
            unauthorizedFailureCount
        case .missingAuthentication:
            missingAuthenticationFailureCount
        case .transient:
            failureCount
        }
        let suppressAuthEscalation =
            escalationBucket != .transient
                && !escalateUnauthorized
        let decision = retryPolicy.decision(
            for: failure,
            failureCount: decisionFailureCount,
            jitterUnitInterval: Double.random(in: 0 ... 1),
            escalateUnauthorized: !suppressAuthEscalation
        )
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
            let delaySeconds = credentialPolicy.boundedRetryDelay(
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
                transient: escalationBucket == .transient
                    ? min(failureCount + 1, 20) : failureCount,
                unauthorized: escalationBucket == .unauthorized
                    ? min(unauthorizedFailureCount + 1, 20)
                    : unauthorizedFailureCount,
                missingAuthentication: escalationBucket == .missingAuthentication
                    ? min(missingAuthenticationFailureCount + 1, 20)
                    : missingAuthenticationFailureCount
            )
        }
    }

}

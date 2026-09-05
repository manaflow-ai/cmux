public import Foundation

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
    private var loop: Task<Void, Never>?
    private let rotationGate = IrxRelayCredentialRotationGate()
    /// A cancelled refresh task can still return from an in-flight broker
    /// request. The generation prevents that old task from rotating relay
    /// credentials or invoking registration after a newer foreground loop
    /// owns the lifecycle.
    private var loopGeneration: UInt64 = 0
    /// Runs after every successful rotation. Hosts re-register here so their
    /// advertised relay hint (server-capped at a 1h lifetime) never expires.
    public var onRotation: (@Sendable () async -> Void)?

    public init(
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor,
        journal: IrxJournal
    ) {
        self.broker = broker
        self.endpoint = endpoint
        self.journal = journal
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
    public func start() async {
        guard loop == nil else { return }
        loopGeneration &+= 1
        let generation = loopGeneration
        let rotationGeneration = await rotationGate.begin()
        guard generation == loopGeneration else { return }
        loop = Task {
            await self.run(
                generation: generation,
                rotationGeneration: rotationGeneration
            )
        }
        journal.record("credential-autopilot", "started")
    }

    /// Stops the refresh loop and invalidates any in-flight rotation it owns.
    public func stop() async {
        loopGeneration &+= 1
        await rotationGate.invalidate()
        loop?.cancel()
        loop = nil
        journal.record("credential-autopilot", "stopped")
    }

    /// Foreground/resume kick: restart the loop so a suspension can never
    /// leave a stale sleep deadline in charge of renewal.
    public func kick() async {
        loopGeneration &+= 1
        let generation = loopGeneration
        await rotationGate.invalidate()
        let rotationGeneration = await rotationGate.begin()
        guard generation == loopGeneration else { return }
        loop?.cancel()
        loop = Task {
            await self.run(
                generation: generation,
                rotationGeneration: rotationGeneration
            )
        }
        journal.record("credential-autopilot", "kicked")
    }

    private func run(generation: UInt64, rotationGeneration: UInt64) async {
        while !Task.isCancelled && generation == loopGeneration {
            let now = Date()
            let credentials = await broker.cachedRelayCredentials()
            guard generation == loopGeneration, !Task.isCancelled else { return }
            if let soonest = credentials.map({
                IrxRelayCredentialPolicy.refreshDate(
                    for: $0, jitter: Double.random(in: 0...10))
            }).min(), soonest > now {
                let wait = soonest.timeIntervalSince(now)
                journal.record(
                    "credential-autopilot", "sleeping",
                    ["until_refresh_s": String(Int(wait))]
                )
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled || generation != loopGeneration { return }
            }
            do {
                let minted = try await broker.mintRelayCredentials()
                guard generation == loopGeneration, !Task.isCancelled else { return }
                // This check must live inside the endpoint-side mutation too:
                // the actor can re-enter while the broker request above is
                // suspended, after which an old loop must be unable to rotate
                // the endpoint owned by a newer loop.
                await endpoint.rotateCredentialsIfCurrent(
                    minted,
                    rotationGeneration: rotationGeneration,
                    gate: rotationGate
                )
                guard generation == loopGeneration, !Task.isCancelled else { return }
                await onRotation?()
            } catch {
                if Task.isCancelled || generation != loopGeneration { return }
                let expiry = credentials.map(\.expiresAt).max() ?? Date()
                let delay = IrxRelayCredentialPolicy.retryDelay(expiresAt: expiry, now: Date())
                journal.record(
                    "credential-autopilot", "mint-failed",
                    [
                        "error": String(describing: error),
                        "retry": String(describing: delay),
                    ]
                )
                try? await Task.sleep(for: delay)
                if Task.isCancelled || generation != loopGeneration { return }
            }
        }
    }
}

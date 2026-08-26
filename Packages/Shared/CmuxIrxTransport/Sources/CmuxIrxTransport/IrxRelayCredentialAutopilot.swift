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

    public init(
        broker: IrxBrokerService,
        endpoint: IrxEndpointSupervisor,
        journal: IrxJournal
    ) {
        self.broker = broker
        self.endpoint = endpoint
        self.journal = journal
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
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
            }
            do {
                let minted = try await broker.mintRelayCredentials()
                await endpoint.rotateCredentials(minted)
            } catch {
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
            }
        }
    }
}

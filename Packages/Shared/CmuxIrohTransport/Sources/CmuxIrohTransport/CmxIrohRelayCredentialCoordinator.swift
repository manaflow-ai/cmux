public import CMUXMobileCore
public import Foundation

/// Keeps endpoint-scoped relay credentials fresh without recreating the endpoint.
public actor CmxIrohRelayCredentialCoordinator {
    private static let minimumUsefulValidity: TimeInterval = 10
    private static let postExpiryRetryDelay: TimeInterval = 1

    private struct Binding: Equatable, Sendable {
        let id: String
        let endpointIdentity: CmxIrohPeerIdentity
    }

    private struct InstalledCredential: Equatable, Sendable {
        let refreshAfter: Date
        let expiresAt: Date
    }

    private struct PendingPersistence: Sendable {
        let response: CmxIrohRelayTokenResponse
        let binding: Binding
        let revision: UInt64
    }

    private let supervisor: CmxIrohEndpointSupervisor
    private let broker: any CmxIrohRelayTokenServing
    private let managedRelayURLs: Set<String>
    private let selectedRelayURLs: Set<String>
    private let clock: any CmxIrohRelayClock
    private let jitter: @Sendable (_ now: Date, _ refreshAfter: Date) -> Date
    private let retrySchedule: CmxIrohRetrySchedule
    private let retryJitter: @Sendable () -> Double
    private let credentialDidInstall: @Sendable (CmxIrohRelayTokenResponse) async -> Void
    private var binding: Binding?
    private var installedCredential: InstalledCredential?
    private var lifecycleRevision: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var pendingPersistence: PendingPersistence?

    /// Creates an inactive relay credential coordinator.
    public init(
        supervisor: CmxIrohEndpointSupervisor,
        broker: any CmxIrohRelayTokenServing,
        managedRelayURLs: Set<String>,
        selectedRelayURLs: Set<String>? = nil,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        jitter: @escaping @Sendable (_ now: Date, _ refreshAfter: Date) -> Date = {
            now,
            refreshAfter in
            let window = min(30, max(0, refreshAfter.timeIntervalSince(now)))
            return refreshAfter.addingTimeInterval(-Double.random(in: 0 ... window))
        },
        retrySchedule: CmxIrohRetrySchedule = CmxIrohRetrySchedule(),
        retryJitter: @escaping @Sendable () -> Double = {
            Double.random(in: 0 ... 1)
        },
        credentialDidInstall: @escaping @Sendable (
            CmxIrohRelayTokenResponse
        ) async -> Void = { _ in }
    ) {
        self.supervisor = supervisor
        self.broker = broker
        self.managedRelayURLs = managedRelayURLs
        self.selectedRelayURLs = selectedRelayURLs ?? managedRelayURLs
        self.clock = clock
        self.jitter = jitter
        self.retrySchedule = retrySchedule
        self.retryJitter = retryJitter
        self.credentialDidInstall = credentialDidInstall
    }

    /// Starts refresh scheduling for one exact registered endpoint binding.
    ///
    /// A bootstrap credential is installed before scheduling. Bootstrap
    /// validation failure is returned to the caller, while an immediate broker
    /// retry is still scheduled so registration remains committed and direct
    /// connectivity remains available.
    public func activate(
        bindingID: String,
        endpointIdentity: CmxIrohPeerIdentity,
        bootstrap: CmxIrohRelayTokenResponse? = nil
    ) async throws {
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        refreshTask?.cancel()
        let expectedBinding = Binding(id: bindingID, endpointIdentity: endpointIdentity)
        binding = expectedBinding
        installedCredential = nil

        if let bootstrap {
            do {
                let installed = try await install(
                    bootstrap,
                    binding: expectedBinding,
                    revision: revision
                )
                startLoop(revision: revision, firstRefresh: installed.refreshAfter)
                return
            } catch {
                if isCurrent(revision), !Task.isCancelled {
                    startLoop(revision: revision, firstRefresh: nil)
                }
                throw error
            }
        }
        do {
            let response = try await broker.issueRelayToken(
                bindingID: bindingID,
                endpointID: endpointIdentity
            )
            let installed = try await install(
                response,
                binding: expectedBinding,
                revision: revision
            )
            startLoop(revision: revision, firstRefresh: installed.refreshAfter)
        } catch {
            if isCurrent(revision), !Task.isCancelled {
                let delay = retryDelay(failureCount: 0, error: error)
                startLoop(
                    revision: revision,
                    firstRefresh: clock.now().addingTimeInterval(delay),
                    initialFailureCount: 1
                )
            }
        }
    }

    /// Cancels all scheduled refresh work and forgets binding-scoped state.
    public func deactivate() {
        lifecycleRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        persistenceTask?.cancel()
        persistenceTask = nil
        pendingPersistence = nil
        binding = nil
        installedCredential = nil
    }

    /// Returns the hard expiry of the last successfully installed credential.
    public func credentialExpiresAt() -> Date? {
        installedCredential?.expiresAt
    }

    private func startLoop(
        revision: UInt64,
        firstRefresh: Date?,
        initialFailureCount: Int = 0
    ) {
        refreshTask = Task { [weak self] in
            await self?.run(
                revision: revision,
                firstRefresh: firstRefresh,
                initialFailureCount: initialFailureCount
            )
        }
    }

    private func run(
        revision: UInt64,
        firstRefresh: Date?,
        initialFailureCount: Int
    ) async {
        var deadline = firstRefresh
        var failureCount = initialFailureCount
        while isCurrent(revision) {
            if let deadline {
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
            }
            guard isCurrent(revision), !Task.isCancelled, let binding else { return }
            do {
                let response = try await broker.issueRelayToken(
                    bindingID: binding.id,
                    endpointID: binding.endpointIdentity
                )
                let installed = try await install(
                    response,
                    binding: binding,
                    revision: revision
                )
                failureCount = 0
                deadline = installed.refreshAfter
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(revision), !Task.isCancelled else { return }
                let now = clock.now()
                let delay = retryDelay(failureCount: failureCount, error: error)
                deadline = retryDeadline(
                    now: now,
                    backoff: delay,
                    honorsServerFloor: (error as? CmxIrohTrustBrokerClientError)?
                        .retryAfterSeconds != nil
                )
                failureCount = min(failureCount + 1, 20)
            }
        }
    }

    /// Keeps refresh retries inside the useful lifetime of an installed token.
    ///
    /// Exponential backoff alone can place the first retry at expiry because
    /// five-minute relay tokens refresh only one minute early. Halving the
    /// remaining lifetime preserves multiple bounded attempts. Once too little
    /// validity remains for a useful mint-and-install round trip, retry just
    /// after expiry and reset the backoff instead of growing a long outage.
    private func retryDeadline(
        now: Date,
        backoff: TimeInterval,
        honorsServerFloor: Bool
    ) -> Date {
        if honorsServerFloor {
            return now.addingTimeInterval(backoff)
        }
        guard let expiresAt = installedCredential?.expiresAt,
              now < expiresAt else {
            return now.addingTimeInterval(backoff)
        }
        let remainingValidity = expiresAt.timeIntervalSince(now)
        guard remainingValidity > Self.minimumUsefulValidity else {
            return expiresAt.addingTimeInterval(Self.postExpiryRetryDelay)
        }
        return min(
            now.addingTimeInterval(backoff),
            now.addingTimeInterval(remainingValidity / 2)
        )
    }

    private func retryDelay(failureCount: Int, error: any Error) -> TimeInterval {
        retrySchedule.delay(
            failureCount: failureCount,
            retryAfterSeconds: (error as? CmxIrohTrustBrokerClientError)?
                .retryAfterSeconds,
            jitterUnitInterval: retryJitter()
        )
    }

    private func install(
        _ response: CmxIrohRelayTokenResponse,
        binding expectedBinding: Binding,
        revision: UInt64
    ) async throws -> InstalledCredential {
        try Task.checkCancellation()
        guard isCurrent(revision), binding == expectedBinding else {
            throw CancellationError()
        }
        guard response.relayFleet.count == managedRelayURLs.count,
              Set(response.relayFleet) == managedRelayURLs else {
            throw CmxIrohRelayCredentialCoordinatorError.relayFleetMismatch
        }
        let now = clock.now()
        let configurations = try response.relayConfigurations(now: now)
        let selectedConfigurations = configurations.filter {
            selectedRelayURLs.contains($0.url)
        }
        guard !selectedRelayURLs.isEmpty,
              selectedConfigurations.count == selectedRelayURLs.count,
              selectedRelayURLs.isSubset(of: managedRelayURLs) else {
            throw CmxIrohRelayCredentialCoordinatorError.relayFleetMismatch
        }
        try Task.checkCancellation()
        guard isCurrent(revision), binding == expectedBinding else {
            throw CancellationError()
        }
        if selectedRelayURLs == managedRelayURLs {
            try await supervisor.replaceRelays(
                configurations,
                expectedIdentity: expectedBinding.endpointIdentity
            )
        } else {
            let profile = try CmxIrohEndpointRelayProfile(
                managedRelayURLs: selectedRelayURLs,
                relays: selectedConfigurations
            )
            try await supervisor.replaceRelayProfile(
                profile,
                expectedIdentity: expectedBinding.endpointIdentity
            )
        }
        try Task.checkCancellation()
        guard isCurrent(revision), binding == expectedBinding,
              let refreshAfter = selectedConfigurations.map(\.refreshAfter).min(),
              let expiresAt = selectedConfigurations.map(\.expiresAt).min() else {
            throw CancellationError()
        }
        let installed = InstalledCredential(
            refreshAfter: scheduledRefresh(refreshAfter),
            expiresAt: expiresAt
        )
        installedCredential = installed
        enqueuePersistence(
            response: response,
            binding: expectedBinding,
            revision: revision
        )
        return installed
    }

    /// Persists only the newest installed credential on one cancellable serial lane.
    /// Runtime installation and refresh scheduling never await secure storage.
    private func enqueuePersistence(
        response: CmxIrohRelayTokenResponse,
        binding: Binding,
        revision: UInt64
    ) {
        pendingPersistence = PendingPersistence(
            response: response,
            binding: binding,
            revision: revision
        )
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            await self?.runPersistenceQueue()
        }
    }

    private func runPersistenceQueue() async {
        while !Task.isCancelled, let next = pendingPersistence {
            pendingPersistence = nil
            guard isCurrent(next.revision), binding == next.binding else { continue }
            await credentialDidInstall(next.response)
        }
        persistenceTask = nil
        if pendingPersistence != nil, !Task.isCancelled {
            persistenceTask = Task { [weak self] in
                await self?.runPersistenceQueue()
            }
        }
    }

    private func scheduledRefresh(_ refreshAfter: Date) -> Date {
        let now = clock.now()
        let candidate = jitter(now, refreshAfter)
        return min(refreshAfter, max(now, candidate))
    }

    private func isCurrent(_ revision: UInt64) -> Bool {
        lifecycleRevision == revision
    }
}

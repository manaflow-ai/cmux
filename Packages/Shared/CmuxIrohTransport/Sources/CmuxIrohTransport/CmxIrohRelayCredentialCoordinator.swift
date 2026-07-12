public import CMUXMobileCore
public import Foundation

/// Keeps endpoint-scoped relay credentials fresh without recreating the endpoint.
public actor CmxIrohRelayCredentialCoordinator {
    private struct Binding: Equatable, Sendable {
        let id: String
        let endpointIdentity: CmxIrohPeerIdentity
    }

    private struct InstalledCredential: Equatable, Sendable {
        let refreshAfter: Date
        let expiresAt: Date
    }

    private let supervisor: CmxIrohEndpointSupervisor
    private let broker: any CmxIrohRelayTokenServing
    private let managedRelayURLs: Set<String>
    private let clock: any CmxIrohRelayClock
    private let jitter: @Sendable (_ now: Date, _ refreshAfter: Date) -> Date
    private let credentialDidInstall: @Sendable (CmxIrohRelayTokenResponse) async -> Void
    private var binding: Binding?
    private var installedCredential: InstalledCredential?
    private var lifecycleRevision: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    /// Creates an inactive relay credential coordinator.
    public init(
        supervisor: CmxIrohEndpointSupervisor,
        broker: any CmxIrohRelayTokenServing,
        managedRelayURLs: Set<String>,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        jitter: @escaping @Sendable (_ now: Date, _ refreshAfter: Date) -> Date = {
            now,
            refreshAfter in
            let window = min(30, max(0, refreshAfter.timeIntervalSince(now)))
            return refreshAfter.addingTimeInterval(-Double.random(in: 0 ... window))
        },
        credentialDidInstall: @escaping @Sendable (
            CmxIrohRelayTokenResponse
        ) async -> Void = { _ in }
    ) {
        self.supervisor = supervisor
        self.broker = broker
        self.managedRelayURLs = managedRelayURLs
        self.clock = clock
        self.jitter = jitter
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
                startLoop(
                    revision: revision,
                    firstRefresh: clock.now().addingTimeInterval(60)
                )
            }
        }
    }

    /// Cancels all scheduled refresh work and forgets binding-scoped state.
    public func deactivate() {
        lifecycleRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        binding = nil
        installedCredential = nil
    }

    /// Returns the hard expiry of the last successfully installed credential.
    public func credentialExpiresAt() -> Date? {
        installedCredential?.expiresAt
    }

    private func startLoop(revision: UInt64, firstRefresh: Date?) {
        refreshTask = Task { [weak self] in
            await self?.run(revision: revision, firstRefresh: firstRefresh)
        }
    }

    private func run(revision: UInt64, firstRefresh: Date?) async {
        var deadline = firstRefresh
        var retryDelay: TimeInterval = 60
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
                retryDelay = 60
                deadline = installed.refreshAfter
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(revision), !Task.isCancelled else { return }
                deadline = clock.now().addingTimeInterval(retryDelay)
                retryDelay = min(retryDelay * 2, 30 * 60)
            }
        }
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
        try Task.checkCancellation()
        guard isCurrent(revision), binding == expectedBinding else {
            throw CancellationError()
        }
        try await supervisor.replaceRelays(
            configurations,
            expectedIdentity: expectedBinding.endpointIdentity
        )
        try Task.checkCancellation()
        guard isCurrent(revision), binding == expectedBinding,
              let refreshAfter = configurations.map(\.refreshAfter).min(),
              let expiresAt = configurations.map(\.expiresAt).min() else {
            throw CancellationError()
        }
        let installed = InstalledCredential(
            refreshAfter: scheduledRefresh(refreshAfter),
            expiresAt: expiresAt
        )
        installedCredential = installed
        await credentialDidInstall(response)
        return installed
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

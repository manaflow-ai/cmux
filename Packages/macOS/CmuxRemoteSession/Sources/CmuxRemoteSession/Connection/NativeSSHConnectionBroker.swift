public import CmuxCore
public import CmuxRemoteWorkspace
internal import CmuxFoundation
internal import Foundation

/// Owns cmux-native SSH master lifetimes and serializes reconnect attempts per endpoint.
///
/// Workspace ownership is reference-counted by `ownerWorkspaceID`. Ordinary
/// cleanup exits a cmux-owned master only for its last workspace; authenticated
/// inherited-forward recovery may reap an exclusively owned master and
/// invalidates every sharing workspace. Custom control paths remain entirely
/// user-managed. Connection attempts for the same `(destination, port)` run
/// one at a time, while different endpoints remain independent.
@MainActor
public final class NativeSSHConnectionBroker {
    nonisolated let sharingOptions: SSHConnectionSharingOptions
    let clock: any RemoteProxyRetryClock
    private let jitterMilliseconds: @MainActor @Sendable () -> Int
    let cleanupLauncherOverride: (@MainActor @Sendable (NativeSSHControlMasterCleanupRequest) -> Void)?
    private nonisolated let inheritedMasterReapEventHub:
        NativeSSHControlMasterReapEventHub
    nonisolated let controlMasterOwnershipRegistry:
        any NativeSSHControlMasterOwnershipTracking
    private let inheritedMasterReapCoordinator:
        NativeSSHControlMasterReapCoordinator

    var ownerLeases: [UUID: [NativeSSHControlMasterKey: WorkspaceRemoteConfiguration]] = [:]
    var ownersByControlMaster: [NativeSSHControlMasterKey: Set<UUID>] = [:]
    var attemptStates: [NativeSSHConnectionKey: NativeSSHConnectionAttemptState] = [:]
    var pendingCleanupsByControlMaster: [
        NativeSSHControlMasterKey: NativeSSHControlMasterPendingCleanup
    ] = [:]
    var cleanupRetryTasks: [NativeSSHControlMasterKey: Task<Void, Never>] = [:]
    var cleanupProcesses: [UUID: Process] = [:]
    var cleanupControlMasterKeysByProcessID: [UUID: NativeSSHControlMasterKey] = [:]
    var cleanupProcessIDByControlMaster: [NativeSSHControlMasterKey: UUID] = [:]
    var cleanupTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    var cleanupTerminationRequested: Set<UUID> = []
    var cleanupAuthorizations: [
        UUID: NativeSSHControlMasterExclusiveUseAuthorization
    ] = [:]

    /// Creates the process-wide broker with continuous-clock jitter and local cleanup launching.
    ///
    /// - Parameter clock: Clock used for the bounded delay between same-host attempts.
    public nonisolated init(clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()) {
        self.sharingOptions = SSHConnectionSharingOptions()
        self.clock = clock
        self.jitterMilliseconds = { Int.random(in: 100...350) }
        self.cleanupLauncherOverride = nil
        let eventHub = NativeSSHControlMasterReapEventHub()
        let ownershipRegistry =
            NativeSSHControlMasterOwnershipRegistry(
                sharingOptions: sharingOptions
            )
        self.inheritedMasterReapEventHub = eventHub
        self.controlMasterOwnershipRegistry = ownershipRegistry
        self.inheritedMasterReapCoordinator =
            NativeSSHControlMasterReapCoordinator(
                sharingOptions: sharingOptions,
                processRunner: RemoteSessionProcessRunner(),
                eventHub: eventHub,
                ownershipRegistry: ownershipRegistry
            )
    }

    /// Creates a broker with an injected cleanup launcher.
    ///
    /// This initializer lets composition roots and tests observe cleanup
    /// without replacing process-wide static state.
    ///
    /// - Parameters:
    ///   - clock: Clock used for the bounded delay between same-host attempts.
    ///   - cleanupLauncher: Receives the last-owner `ssh -O exit` request.
    public nonisolated init(
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock(),
        cleanupLauncher: @escaping @MainActor @Sendable (NativeSSHControlMasterCleanupRequest) -> Void
    ) {
        self.sharingOptions = SSHConnectionSharingOptions()
        self.clock = clock
        self.jitterMilliseconds = { Int.random(in: 100...350) }
        self.cleanupLauncherOverride = cleanupLauncher
        let eventHub = NativeSSHControlMasterReapEventHub()
        let ownershipRegistry =
            NativeSSHControlMasterOwnershipRegistry(
                sharingOptions: sharingOptions
            )
        self.inheritedMasterReapEventHub = eventHub
        self.controlMasterOwnershipRegistry = ownershipRegistry
        self.inheritedMasterReapCoordinator =
            NativeSSHControlMasterReapCoordinator(
                sharingOptions: sharingOptions,
                processRunner: RemoteSessionProcessRunner(),
                eventHub: eventHub,
                ownershipRegistry: ownershipRegistry
            )
    }

    nonisolated init(
        sharingOptions: SSHConnectionSharingOptions,
        clock: any RemoteProxyRetryClock,
        jitterMilliseconds: @escaping @MainActor @Sendable () -> Int,
        cleanupLauncher:
            (@MainActor @Sendable (NativeSSHControlMasterCleanupRequest) -> Void)?,
        inheritedMasterReapRunner: any RemoteSessionProcessRunning =
            RemoteSessionProcessRunner(),
        controlMasterOwnershipRegistry:
            any NativeSSHControlMasterOwnershipTracking
    ) {
        self.sharingOptions = sharingOptions
        self.clock = clock
        self.jitterMilliseconds = jitterMilliseconds
        self.cleanupLauncherOverride = cleanupLauncher
        let eventHub = NativeSSHControlMasterReapEventHub()
        self.inheritedMasterReapEventHub = eventHub
        self.controlMasterOwnershipRegistry = controlMasterOwnershipRegistry
        self.inheritedMasterReapCoordinator =
            NativeSSHControlMasterReapCoordinator(
                sharingOptions: sharingOptions,
                processRunner: inheritedMasterReapRunner,
                eventHub: eventHub,
                ownershipRegistry: controlMasterOwnershipRegistry
            )
    }

    /// Retains the cmux-owned master used by a configured workspace.
    ///
    /// Reconfiguring the same master replaces its configuration generation.
    /// A different master may temporarily overlap until the previous remote
    /// session finishes cleanup and releases its exact configuration.
    ///
    /// - Parameter configuration: Owner-scoped workspace configuration.
    @discardableResult
    public func retainWorkspace(_ configuration: WorkspaceRemoteConfiguration) -> WorkspaceRemoteConfiguration {
        guard let ownerWorkspaceID = configuration.ownerWorkspaceID else { return configuration }
        guard configuration.transport == .ssh else { return configuration }
        let effectiveOptions = sharingOptions.mergingDefaults(
            into: configuration.sshOptions
        )
        guard sharingOptions.cmuxOwnedControlPath(
            in: effectiveOptions
        ) != nil else {
            return configuration
        }
        let leasedConfiguration =
            configuration.withSSHControlMasterLeaseGeneration(UUID())
        if let reapKey = NativeSSHControlMasterReapLeaseKey(
            configuration: leasedConfiguration,
            sharingOptions: sharingOptions
        ) {
            inheritedMasterReapCoordinator.retainWorkspace(
                leasedConfiguration,
                ownerWorkspaceID: ownerWorkspaceID,
                key: reapKey
            )
        }
        let nextKey = NativeSSHControlMasterKey(
            configuration: leasedConfiguration,
            sharingOptions: sharingOptions
        )
        // An unresolved `%C` template still needs a generation so the
        // coordinator can retain its exact resolved socket before reuse.
        // Lifecycle ownership remains exact-path-only.
        guard let nextKey else { return leasedConfiguration }
        if let lease = NativeSSHControlMasterLeaseIdentity(
            configuration: leasedConfiguration
        ) {
            _ = controlMasterOwnershipRegistry.retain(
                controlPath: nextKey.controlPath,
                lease: lease
            )
        }
        cancelCleanup(for: nextKey)
        var leases = ownerLeases[ownerWorkspaceID] ?? [:]
        let isNewMaster = leases[nextKey] == nil
        leases[nextKey] = leasedConfiguration
        ownerLeases[ownerWorkspaceID] = leases
        if isNewMaster {
            ownersByControlMaster[nextKey, default: []].insert(ownerWorkspaceID)
        }
        return leasedConfiguration
    }

    /// Releases a workspace lease and closes the master only for its last owner.
    ///
    /// A stale configuration cannot release a newer lease installed for the
    /// same workspace.
    ///
    /// - Parameter configuration: Exact owner-scoped configuration being released.
    public func releaseWorkspace(_ configuration: WorkspaceRemoteConfiguration) {
        guard let ownerWorkspaceID = configuration.ownerWorkspaceID,
              let generation = configuration.sshControlMasterLeaseGeneration else {
            return
        }
        if let lease = NativeSSHControlMasterLeaseIdentity(
            configuration: configuration
        ) {
            controlMasterOwnershipRegistry.release(lease: lease)
        }
        if let reapKey = NativeSSHControlMasterReapLeaseKey(
            configuration: configuration,
            sharingOptions: sharingOptions
        ) {
            inheritedMasterReapCoordinator.releaseWorkspace(
                ownerWorkspaceID: ownerWorkspaceID,
                generation: generation,
                key: reapKey
            )
        }
        guard let key = NativeSSHControlMasterKey(
            configuration: configuration,
            sharingOptions: sharingOptions
        ),
              ownerLeases[ownerWorkspaceID]?[key]?.sshControlMasterLeaseGeneration == generation else {
            return
        }
        removeLease(ownerWorkspaceID: ownerWorkspaceID, key: key)
    }

    /// Registers this process before a coordinator adopts an exact socket.
    nonisolated func retainResolvedControlMasterLease(
        for configuration: WorkspaceRemoteConfiguration,
        controlPath: String
    ) -> Bool {
        guard let lease = NativeSSHControlMasterLeaseIdentity(
            configuration: configuration
        ) else {
            return false
        }
        return controlMasterOwnershipRegistry.retain(
            controlPath: controlPath,
            lease: lease
        )
    }

    /// Reaps an exclusively owned inherited master after remote metadata proof.
    func reapInheritedControlMaster(
        for configuration: WorkspaceRemoteConfiguration,
        resolvedControlPath: String,
        metadataProbeCommand: String
    ) async -> NativeSSHControlMasterReapOutcome {
        await inheritedMasterReapCoordinator.reap(
            for: configuration,
            resolvedControlPath: resolvedControlPath,
            metadataProbeCommand: metadataProbeCommand
        )
    }

    /// Observes successful reaps for one exact cmux-owned control socket.
    nonisolated func controlMasterReapEvents(
        controlPath: String
    ) async -> AsyncStream<UUID>? {
        guard !controlPath.contains("%"),
              sharingOptions.cmuxOwnedControlPath(in: [
                  "ControlMaster=auto",
                  "ControlPath=\(controlPath)",
              ]) == controlPath else {
            return nil
        }
        return await inheritedMasterReapEventHub.events(
            controlPath: controlPath
        )
    }

    /// Runs one connection attempt after acquiring the endpoint's FIFO permit.
    ///
    /// Same-endpoint attempts are separated by 100–350 ms of injected-clock
    /// jitter. The bounded, cancellable delay is intentional reconnect
    /// staggering, not polling; cancellation removes a queued waiter.
    ///
    /// - Parameters:
    ///   - configuration: Remote endpoint to coordinate.
    ///   - operation: One complete blocking connection attempt, exposed as async by the caller.
    /// - Returns: The operation result.
    public func withConnectionAttempt<Result: Sendable>(
        for configuration: WorkspaceRemoteConfiguration,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard let key = NativeSSHConnectionKey(
            configuration: configuration,
            sharingOptions: sharingOptions
        ) else {
            return try await operation()
        }
        let permit = try await acquireConnectionAttempt(for: key)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            releaseConnectionAttempt(permit)
            return result
        } catch {
            releaseConnectionAttempt(permit)
            throw error
        }
    }

    private func acquireConnectionAttempt(
        for key: NativeSSHConnectionKey
    ) async throws -> NativeSSHConnectionPermit {
        try Task.checkCancellation()
        var state = attemptStates[key] ?? NativeSSHConnectionAttemptState()
        if state.activeToken == nil, state.cooldownToken == nil {
            let token = UUID()
            state.activeToken = token
            attemptStates[key] = state
            return NativeSSHConnectionPermit(key: key, token: token)
        }

        let waiterToken = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task<Never, Never>.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                var queuedState = attemptStates[key] ?? NativeSSHConnectionAttemptState()
                queuedState.waiterOrder.append(waiterToken)
                queuedState.waiters[waiterToken] = continuation
                attemptStates[key] = queuedState
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterToken, for: key)
            }
        }
    }

    private func releaseConnectionAttempt(_ permit: NativeSSHConnectionPermit) {
        guard var state = attemptStates[permit.key],
              state.activeToken == permit.token else {
            return
        }
        state.activeToken = nil
        guard !state.waiters.isEmpty else {
            state.cooldownTask?.cancel()
            attemptStates.removeValue(forKey: permit.key)
            return
        }

        let cooldownToken = UUID()
        let delay = min(350, max(100, jitterMilliseconds()))
        let clock = self.clock
        state.cooldownToken = cooldownToken
        state.cooldownTask = Task { @MainActor in
            guard (try? await clock.sleep(forMilliseconds: delay)) != nil else { return }
            self.grantNextWaiter(for: permit.key, cooldownToken: cooldownToken)
        }
        attemptStates[permit.key] = state
    }

    private func grantNextWaiter(
        for key: NativeSSHConnectionKey,
        cooldownToken: UUID
    ) {
        guard var state = attemptStates[key],
              state.cooldownToken == cooldownToken else {
            return
        }
        state.cooldownTask = nil
        state.cooldownToken = nil
        if let continuation = state.nextWaiter() {
            let permitToken = UUID()
            state.activeToken = permitToken
            attemptStates[key] = state
            continuation.resume(returning: NativeSSHConnectionPermit(
                key: key,
                token: permitToken
            ))
            return
        }
        attemptStates.removeValue(forKey: key)
    }

    private func cancelWaiter(_ waiterToken: UUID, for key: NativeSSHConnectionKey) {
        guard var state = attemptStates[key],
              let continuation = state.waiters.removeValue(forKey: waiterToken) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if state.activeToken == nil, state.waiters.isEmpty {
            state.cooldownTask?.cancel()
            attemptStates.removeValue(forKey: key)
        } else {
            attemptStates[key] = state
        }
    }

}

public import CmuxCore
public import CmuxRemoteWorkspace
internal import CmuxFoundation
internal import Darwin
internal import Foundation

private enum NativeSSHCleanupPolicy {
    static let processTimeoutMilliseconds = 5_000
    static let forcedTerminationDelayMilliseconds = 1_000
    static let retryDelayMilliseconds = 31_000
}

/// Owns cmux-native SSH master lifetimes and serializes reconnect attempts per endpoint.
///
/// Workspace ownership is reference-counted by `ownerWorkspaceID`. Only the
/// last workspace using a cmux-owned `ControlPath` may request `ssh -O exit`;
/// custom control paths remain entirely user-managed. Connection attempts for
/// the same `(destination, port)` run one at a time, while different endpoints
/// remain independent.
@MainActor
public final class NativeSSHConnectionBroker {
    private let sharingOptions: SSHConnectionSharingOptions
    private let clock: any RemoteProxyRetryClock
    private let jitterMilliseconds: @MainActor @Sendable () -> Int
    private let cleanupLauncherOverride: (@MainActor @Sendable (NativeSSHControlMasterCleanupRequest) -> Void)?

    private var ownerLeases: [UUID: [NativeSSHControlMasterKey: WorkspaceRemoteConfiguration]] = [:]
    private var ownersByControlMaster: [NativeSSHControlMasterKey: Set<UUID>] = [:]
    var attemptStates: [NativeSSHConnectionKey: NativeSSHConnectionAttemptState] = [:]
    private var cleanupRequestsByControlMaster: [
        NativeSSHControlMasterKey: NativeSSHControlMasterCleanupRequest
    ] = [:]
    private var cleanupRetryTasks: [NativeSSHControlMasterKey: Task<Void, Never>] = [:]
    private var cleanupProcesses: [UUID: Process] = [:]
    private var cleanupControlMasterKeysByProcessID: [UUID: NativeSSHControlMasterKey] = [:]
    private var cleanupProcessIDByControlMaster: [NativeSSHControlMasterKey: UUID] = [:]
    private var cleanupTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var cleanupTerminationRequested: Set<UUID> = []

    /// Creates the process-wide broker with continuous-clock jitter and local cleanup launching.
    ///
    /// - Parameter clock: Clock used for the bounded delay between same-host attempts.
    public nonisolated init(clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()) {
        self.sharingOptions = SSHConnectionSharingOptions()
        self.clock = clock
        self.jitterMilliseconds = { Int.random(in: 100...350) }
        self.cleanupLauncherOverride = nil
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
    }

    nonisolated init(
        sharingOptions: SSHConnectionSharingOptions,
        clock: any RemoteProxyRetryClock,
        jitterMilliseconds: @escaping @MainActor @Sendable () -> Int,
        cleanupLauncher: @escaping @MainActor @Sendable (NativeSSHControlMasterCleanupRequest) -> Void
    ) {
        self.sharingOptions = sharingOptions
        self.clock = clock
        self.jitterMilliseconds = jitterMilliseconds
        self.cleanupLauncherOverride = cleanupLauncher
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
        let nextKey = NativeSSHControlMasterKey(
            configuration: configuration,
            sharingOptions: sharingOptions
        )
        guard let nextKey else { return configuration }
        cancelCleanup(for: nextKey)
        let leasedConfiguration = configuration.withSSHControlMasterLeaseGeneration(UUID())
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
              let generation = configuration.sshControlMasterLeaseGeneration,
              let key = NativeSSHControlMasterKey(
                configuration: configuration,
                sharingOptions: sharingOptions
              ),
              ownerLeases[ownerWorkspaceID]?[key]?.sshControlMasterLeaseGeneration == generation else {
            return
        }
        removeLease(ownerWorkspaceID: ownerWorkspaceID, key: key)
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

    private func removeLease(ownerWorkspaceID: UUID, key: NativeSSHControlMasterKey) {
        guard var leases = ownerLeases[ownerWorkspaceID],
              let previousConfiguration = leases.removeValue(forKey: key) else {
            return
        }
        if leases.isEmpty {
            ownerLeases.removeValue(forKey: ownerWorkspaceID)
        } else {
            ownerLeases[ownerWorkspaceID] = leases
        }
        var owners = ownersByControlMaster[key] ?? []
        owners.remove(ownerWorkspaceID)
        guard owners.isEmpty else {
            ownersByControlMaster[key] = owners
            return
        }
        ownersByControlMaster.removeValue(forKey: key)
        let arguments = RemoteControlMasterCleanup().cleanupArguments(
            configuration: previousConfiguration
        )
        let authenticationLockPath = sharingOptions.foregroundAuthenticationLockPath(
            destination: previousConfiguration.destination,
            port: previousConfiguration.port,
            options: previousConfiguration.sshOptions
        )
        let request = NativeSSHControlMasterCleanupRequest(
            arguments: arguments,
            environment: previousConfiguration.sshProcessEnvironment,
            authenticationLockPath: authenticationLockPath
        )
        beginCleanup(request, for: key)
    }

    private func beginCleanup(
        _ request: NativeSSHControlMasterCleanupRequest,
        for key: NativeSSHControlMasterKey
    ) {
        if let cleanupLauncherOverride {
            cleanupLauncherOverride(request)
            cleanupRequestsByControlMaster.removeValue(forKey: key)
        } else {
            cleanupRequestsByControlMaster[key] = request
            launchCleanup(request, for: key)
        }
    }

    private func cancelCleanup(for key: NativeSSHControlMasterKey) {
        cleanupRequestsByControlMaster.removeValue(forKey: key)
        cleanupRetryTasks.removeValue(forKey: key)?.cancel()
        guard let cleanupID = cleanupProcessIDByControlMaster[key],
              let process = cleanupProcesses[cleanupID],
              process.isRunning else {
            return
        }
        cleanupTerminationRequested.insert(cleanupID)
        process.terminate()
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

    private func launchCleanup(
        _ request: NativeSSHControlMasterCleanupRequest,
        for key: NativeSSHControlMasterKey
    ) {
        guard cleanupRequestsByControlMaster[key] != nil,
              ownersByControlMaster[key]?.isEmpty != false,
              cleanupProcessIDByControlMaster[key] == nil else {
            return
        }
        let cleanupID = UUID()
        let process = Process()
        let invocation = request.processInvocation
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.cleanupProcessDidTerminate(cleanupID)
            }
        }
        do {
            try process.run()
        } catch {
            scheduleCleanupRetry(for: key)
            return
        }
        cleanupProcesses[cleanupID] = process
        cleanupControlMasterKeysByProcessID[cleanupID] = key
        cleanupProcessIDByControlMaster[key] = cleanupID
        scheduleCleanupTimeout(
            cleanupID,
            afterMilliseconds: NativeSSHCleanupPolicy.processTimeoutMilliseconds
        )
    }

    private func scheduleCleanupRetry(for key: NativeSSHControlMasterKey) {
        guard cleanupRequestsByControlMaster[key] != nil,
              ownersByControlMaster[key]?.isEmpty != false,
              cleanupRetryTasks[key] == nil else {
            return
        }
        let clock = self.clock
        cleanupRetryTasks[key] = Task { @MainActor [weak self] in
            guard (try? await clock.sleep(
                forMilliseconds: NativeSSHCleanupPolicy.retryDelayMilliseconds
            )) != nil,
                  !Task.isCancelled else {
                return
            }
            self?.retryCleanup(for: key)
        }
    }

    private func retryCleanup(for key: NativeSSHControlMasterKey) {
        cleanupRetryTasks.removeValue(forKey: key)
        guard let request = cleanupRequestsByControlMaster[key],
              ownersByControlMaster[key]?.isEmpty != false else {
            cleanupRequestsByControlMaster.removeValue(forKey: key)
            return
        }
        launchCleanup(request, for: key)
    }

    private func scheduleCleanupTimeout(_ cleanupID: UUID, afterMilliseconds delay: Int) {
        let clock = self.clock
        cleanupTimeoutTasks[cleanupID] = Task { @MainActor [weak self] in
            guard (try? await clock.sleep(forMilliseconds: delay)) != nil else { return }
            self?.cleanupProcessTimedOut(cleanupID)
        }
    }

    private func cleanupProcessTimedOut(_ cleanupID: UUID) {
        guard let process = cleanupProcesses[cleanupID], process.isRunning else {
            cleanupProcessDidTerminate(cleanupID)
            return
        }
        if cleanupTerminationRequested.insert(cleanupID).inserted {
            process.terminate()
            scheduleCleanupTimeout(
                cleanupID,
                afterMilliseconds: NativeSSHCleanupPolicy.forcedTerminationDelayMilliseconds
            )
        } else {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func cleanupProcessDidTerminate(_ cleanupID: UUID) {
        cleanupTimeoutTasks.removeValue(forKey: cleanupID)?.cancel()
        let terminationWasRequested = cleanupTerminationRequested.remove(cleanupID) != nil
        let process = cleanupProcesses.removeValue(forKey: cleanupID)
        guard let key = cleanupControlMasterKeysByProcessID.removeValue(forKey: cleanupID) else { return }
        if cleanupProcessIDByControlMaster[key] == cleanupID {
            cleanupProcessIDByControlMaster.removeValue(forKey: key)
        }
        guard cleanupRequestsByControlMaster[key] != nil,
              ownersByControlMaster[key]?.isEmpty != false else {
            return
        }
        if terminationWasRequested ||
            process?.terminationStatus == NativeSSHControlMasterCleanupRequest.retryExitStatus {
            scheduleCleanupRetry(for: key)
        } else {
            cleanupRequestsByControlMaster.removeValue(forKey: key)
        }
    }
}

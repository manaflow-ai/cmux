internal import CmuxCore
internal import Darwin
internal import Foundation

@MainActor
extension NativeSSHConnectionBroker {
    // A cross-process lock holder cannot signal this process when it exits, so
    // cleanup retries use injected, capped deadlines instead of open-ended polling.
    private static let cleanupProcessTimeoutMilliseconds = 5_000
    private static let cleanupForcedTerminationDelayMilliseconds = 1_000
    private static let cleanupRetryDelayMilliseconds = 31_000
    private static let cleanupMaximumRetryCount = 3

    func removeLease(
        ownerWorkspaceID: UUID,
        key: NativeSSHControlMasterKey
    ) {
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
        let request = NativeSSHControlMasterCleanupRequest(
            arguments: arguments,
            environment: previousConfiguration.sshProcessEnvironment
        )
        beginCleanup(request, for: key)
    }

    func beginCleanup(
        _ request: NativeSSHControlMasterCleanupRequest,
        for key: NativeSSHControlMasterKey
    ) {
        if let cleanupLauncherOverride {
            cleanupLauncherOverride(request)
            pendingCleanupsByControlMaster.removeValue(forKey: key)
        } else {
            pendingCleanupsByControlMaster[key] =
                NativeSSHControlMasterPendingCleanup(
                    request: request,
                    retriesRemaining: Self.cleanupMaximumRetryCount
                )
            launchCleanup(request, for: key)
        }
    }

    func cancelCleanup(for key: NativeSSHControlMasterKey) {
        pendingCleanupsByControlMaster.removeValue(forKey: key)
        cleanupRetryTasks.removeValue(forKey: key)?.cancel()
        guard let cleanupID = cleanupProcessIDByControlMaster[key],
              let process = cleanupProcesses[cleanupID],
              process.isRunning else {
            return
        }
        cleanupTerminationRequested.insert(cleanupID)
        process.terminate()
    }

    private func launchCleanup(
        _ request: NativeSSHControlMasterCleanupRequest,
        for key: NativeSSHControlMasterKey
    ) {
        guard pendingCleanupsByControlMaster[key] != nil,
              ownersByControlMaster[key]?.isEmpty != false,
              cleanupProcessIDByControlMaster[key] == nil else {
            return
        }
        guard let authorization = controlMasterOwnershipRegistry.beginCleanup(
            controlPath: key.controlPath
        ) else {
            scheduleCleanupRetry(for: key)
            return
        }
        let cleanupID = UUID()
        let process = Process()
        // The registry authorization already holds the exact authentication
        // and ownership locks; a second shell lock would deadlock itself.
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
            authorization.release()
            scheduleCleanupRetry(for: key)
            return
        }
        cleanupAuthorizations[cleanupID] = authorization
        cleanupProcesses[cleanupID] = process
        cleanupControlMasterKeysByProcessID[cleanupID] = key
        cleanupProcessIDByControlMaster[key] = cleanupID
        scheduleCleanupTimeout(
            cleanupID,
            afterMilliseconds: Self.cleanupProcessTimeoutMilliseconds
        )
    }

    private func scheduleCleanupRetry(for key: NativeSSHControlMasterKey) {
        guard var pendingCleanup = pendingCleanupsByControlMaster[key],
              ownersByControlMaster[key]?.isEmpty != false,
              cleanupRetryTasks[key] == nil else {
            return
        }
        guard pendingCleanup.consumeRetry() else {
            pendingCleanupsByControlMaster.removeValue(forKey: key)
            return
        }
        pendingCleanupsByControlMaster[key] = pendingCleanup
        let clock = self.clock
        cleanupRetryTasks[key] = Task { @MainActor [weak self] in
            guard (try? await clock.sleep(
                forMilliseconds: Self.cleanupRetryDelayMilliseconds
            )) != nil,
                  !Task.isCancelled else {
                return
            }
            self?.retryCleanup(for: key)
        }
    }

    private func retryCleanup(for key: NativeSSHControlMasterKey) {
        cleanupRetryTasks.removeValue(forKey: key)
        guard let pendingCleanup = pendingCleanupsByControlMaster[key],
              ownersByControlMaster[key]?.isEmpty != false else {
            pendingCleanupsByControlMaster.removeValue(forKey: key)
            return
        }
        launchCleanup(pendingCleanup.request, for: key)
    }

    private func scheduleCleanupTimeout(
        _ cleanupID: UUID,
        afterMilliseconds delay: Int
    ) {
        let clock = self.clock
        cleanupTimeoutTasks[cleanupID] = Task { @MainActor [weak self] in
            guard (try? await clock.sleep(forMilliseconds: delay)) != nil else {
                return
            }
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
                afterMilliseconds: Self.cleanupForcedTerminationDelayMilliseconds
            )
        } else {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func cleanupProcessDidTerminate(_ cleanupID: UUID) {
        cleanupTimeoutTasks.removeValue(forKey: cleanupID)?.cancel()
        cleanupAuthorizations.removeValue(forKey: cleanupID)?.release()
        let terminationWasRequested =
            cleanupTerminationRequested.remove(cleanupID) != nil
        cleanupProcesses.removeValue(forKey: cleanupID)
        guard let key =
            cleanupControlMasterKeysByProcessID.removeValue(
                forKey: cleanupID
            ) else {
            return
        }
        if cleanupProcessIDByControlMaster[key] == cleanupID {
            cleanupProcessIDByControlMaster.removeValue(forKey: key)
        }
        guard pendingCleanupsByControlMaster[key] != nil,
              ownersByControlMaster[key]?.isEmpty != false else {
            return
        }
        if terminationWasRequested {
            scheduleCleanupRetry(for: key)
        } else {
            pendingCleanupsByControlMaster.removeValue(forKey: key)
        }
    }
}

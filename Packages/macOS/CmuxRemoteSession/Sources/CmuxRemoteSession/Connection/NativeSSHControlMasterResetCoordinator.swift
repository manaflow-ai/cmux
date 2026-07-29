internal import CmuxCore
internal import CmuxFoundation
internal import Foundation

/// Outcome of one broker-authorized conflicted-master migration.
enum NativeSSHControlMasterResetOutcome: Sendable, Equatable {
    case reset
    case ignored(String)
}

/// Broker-owned state for disruptive ControlMaster resets.
///
/// The parent ``NativeSSHConnectionBroker`` calls every mutating method on the
/// main actor. Keeping this state in one collaborator makes reset authorization
/// and coalescing independent from the normal last-owner cleanup lifecycle.
@MainActor
final class NativeSSHControlMasterResetCoordinator {
    private struct InFlightReset {
        let id: UUID
        let task: Task<NativeSSHControlMasterResetOutcome, Never>
    }

    private let sharingOptions: SSHConnectionSharingOptions
    private let processRunner: any RemoteSessionProcessRunning
    private var leases: [
        UUID: [NativeSSHControlMasterResetKey: WorkspaceRemoteConfiguration]
    ] = [:]
    private var inFlightResets: [
        NativeSSHControlMasterResetKey: InFlightReset
    ] = [:]

    nonisolated init(
        sharingOptions: SSHConnectionSharingOptions,
        processRunner: any RemoteSessionProcessRunning
    ) {
        self.sharingOptions = sharingOptions
        self.processRunner = processRunner
    }

    func retainWorkspace(
        _ configuration: WorkspaceRemoteConfiguration,
        ownerWorkspaceID: UUID,
        key: NativeSSHControlMasterResetKey
    ) {
        var ownerLeases = leases[ownerWorkspaceID] ?? [:]
        ownerLeases[key] = configuration
        leases[ownerWorkspaceID] = ownerLeases
    }

    func releaseWorkspace(
        ownerWorkspaceID: UUID,
        generation: UUID,
        key: NativeSSHControlMasterResetKey
    ) {
        guard var ownerLeases = leases[ownerWorkspaceID],
              ownerLeases[key]?.sshControlMasterLeaseGeneration == generation else {
            return
        }
        ownerLeases.removeValue(forKey: key)
        if ownerLeases.isEmpty {
            leases.removeValue(forKey: ownerWorkspaceID)
        } else {
            leases[ownerWorkspaceID] = ownerLeases
        }
    }

    func reset(
        for configuration: WorkspaceRemoteConfiguration
    ) async -> NativeSSHControlMasterResetOutcome {
        guard let ownerWorkspaceID = configuration.ownerWorkspaceID,
              let generation = configuration.sshControlMasterLeaseGeneration,
              let key = NativeSSHControlMasterResetKey(
                configuration: configuration,
                sharingOptions: sharingOptions
              ),
              leases[ownerWorkspaceID]?[key]?.sshControlMasterLeaseGeneration == generation else {
            return .ignored("workspace no longer owns this cmux SSH master")
        }
        if let inFlight = inFlightResets[key] {
            return await inFlight.task.value
        }

        let effectiveOptions = sharingOptions.mergingDefaults(
            into: configuration.sshOptions
        )
        let arguments = RemoteControlMasterCleanup().cleanupArguments(
            configuration: configuration,
            sshOptionsOverride: effectiveOptions
        )
        let authenticationLockPath = sharingOptions.foregroundAuthenticationLockPath(
            destination: configuration.destination,
            port: configuration.port,
            options: effectiveOptions
        )
        let request = NativeSSHControlMasterCleanupRequest(
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            authenticationLockPath: authenticationLockPath
        )
        let resetID = UUID()
        let processRunner = self.processRunner
        let task = Task {
            await Self.runReset(request: request, processRunner: processRunner)
        }
        inFlightResets[key] = InFlightReset(id: resetID, task: task)
        let outcome = await task.value
        if inFlightResets[key]?.id == resetID {
            inFlightResets.removeValue(forKey: key)
        }
        return outcome
    }

    private nonisolated static func runReset(
        request: NativeSSHControlMasterCleanupRequest,
        processRunner: any RemoteSessionProcessRunning
    ) async -> NativeSSHControlMasterResetOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let invocation = request.processInvocation
                let processRequest = RemoteProcessRequest(
                    executable: invocation.executableURL.path,
                    arguments: invocation.arguments,
                    environment: request.environment,
                    timeout: 5
                )
                do {
                    let result = try processRunner.run(processRequest, operation: nil)
                    if result.status == 0 {
                        continuation.resume(returning: .reset)
                    } else {
                        continuation.resume(returning: .ignored(
                            bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                                ?? "ssh exited \(result.status)"
                        ))
                    }
                } catch {
                    continuation.resume(returning: .ignored(error.localizedDescription))
                }
            }
        }
    }

    private nonisolated static func bestErrorLine(
        stderr: String,
        stdout: String
    ) -> String? {
        for text in [stderr, stdout] {
            if let line = text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

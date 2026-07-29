internal import CmuxCore
internal import CmuxFoundation
internal import CmuxRemoteWorkspace
internal import Foundation

/// Outcome of one broker-authorized conflicted-master migration.
enum NativeSSHControlMasterResetOutcome: Sendable, Equatable {
    case reset
    case deferred(String)
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
        let authorizationKey: NativeSSHControlMasterResetKey
        let task: Task<NativeSSHControlMasterResetOutcome, Never>
    }

    private let sharingOptions: SSHConnectionSharingOptions
    private let processRunner: any RemoteSessionProcessRunning
    private let clock: any RemoteProxyRetryClock
    private let eventHub: NativeSSHControlMasterResetEventHub
    private var leases: [
        UUID: [NativeSSHControlMasterResetKey: WorkspaceRemoteConfiguration]
    ] = [:]
    private var inFlightResets: [
        String: InFlightReset
    ] = [:]

    nonisolated init(
        sharingOptions: SSHConnectionSharingOptions,
        processRunner: any RemoteSessionProcessRunning,
        clock: any RemoteProxyRetryClock,
        eventHub: NativeSSHControlMasterResetEventHub
    ) {
        self.sharingOptions = sharingOptions
        self.processRunner = processRunner
        self.clock = clock
        self.eventHub = eventHub
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
        let remainsOwned = leases.values.contains { $0[key] != nil }
        if !remainsOwned {
            for reset in inFlightResets.values
                where reset.authorizationKey == key {
                reset.task.cancel()
            }
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
              ownsLease(
                ownerWorkspaceID: ownerWorkspaceID,
                generation: generation,
                key: key
              ) else {
            return .ignored("workspace no longer owns this cmux SSH master")
        }

        let effectiveOptions = sharingOptions.mergingDefaults(
            into: configuration.sshOptions
        )
        let pathResolver = NativeSSHControlPathResolver(
            sharingOptions: sharingOptions
        )
        let resolvedControlPath: String?
        if let exactPath = pathResolver.resolvedControlPath(
            effectiveOptions: effectiveOptions
        ) {
            resolvedControlPath = exactPath
        } else {
            resolvedControlPath = await Self.resolveControlPath(
                configuration: configuration,
                effectiveOptions: effectiveOptions,
                resolver: pathResolver,
                processRunner: processRunner
            )
        }
        guard !Task.isCancelled else {
            return .deferred("control-master reset cancelled")
        }
        guard let resolvedControlPath else {
            return .ignored("could not resolve the cmux SSH master socket")
        }
        guard ownsLease(
            ownerWorkspaceID: ownerWorkspaceID,
            generation: generation,
            key: key
        ) else {
            return .ignored("workspace no longer owns this cmux SSH master")
        }
        if let inFlight = inFlightResets[resolvedControlPath] {
            return await inFlight.task.value
        }

        let resolvedOptions = pathResolver.replacingControlPath(
            in: effectiveOptions,
            with: resolvedControlPath
        )
        let arguments = RemoteControlMasterCleanup().cleanupArguments(
            configuration: configuration,
            sshOptionsOverride: resolvedOptions
        )
        let authenticationLockPath = sharingOptions.foregroundAuthenticationLockPath(
            destination: configuration.destination,
            port: configuration.port,
            options: resolvedOptions
        )
        let request = NativeSSHControlMasterCleanupRequest(
            arguments: arguments,
            environment: configuration.sshProcessEnvironment,
            authenticationLockPath: authenticationLockPath
        )
        let resetID = UUID()
        let processRunner = self.processRunner
        let clock = self.clock
        let eventHub = self.eventHub
        let task = Task {
            let outcome = await Self.runReset(
                request: request,
                processRunner: processRunner,
                clock: clock
            )
            if case .reset = outcome {
                eventHub.emit(controlPath: resolvedControlPath)
            }
            return outcome
        }
        inFlightResets[resolvedControlPath] = InFlightReset(
            id: resetID,
            authorizationKey: key,
            task: task
        )
        let outcome = await task.value
        if inFlightResets[resolvedControlPath]?.id == resetID {
            inFlightResets.removeValue(forKey: resolvedControlPath)
        }
        return outcome
    }

    private func ownsLease(
        ownerWorkspaceID: UUID,
        generation: UUID,
        key: NativeSSHControlMasterResetKey
    ) -> Bool {
        leases[ownerWorkspaceID]?[key]?.sshControlMasterLeaseGeneration == generation
    }

    private nonisolated static func resolveControlPath(
        configuration: WorkspaceRemoteConfiguration,
        effectiveOptions: [String],
        resolver: NativeSSHControlPathResolver,
        processRunner: any RemoteSessionProcessRunning
    ) async -> String? {
        let cancellation = RemoteProcessCancellationOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let request = RemoteProcessRequest(
                        executable: "/usr/bin/ssh",
                        arguments: resolver.resolutionArguments(
                            configuration: configuration,
                            effectiveOptions: effectiveOptions
                        ),
                        environment: configuration.sshProcessEnvironment,
                        timeout: 5
                    )
                    do {
                        let result = try processRunner.run(
                            request,
                            operation: cancellation
                        )
                        guard result.status == 0 else {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(returning: resolver.resolvedControlPath(
                            effectiveOptions: effectiveOptions,
                            sshConfigOutput: result.stdout
                        ))
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private nonisolated static func runReset(
        request: NativeSSHControlMasterCleanupRequest,
        processRunner: any RemoteSessionProcessRunning,
        clock: any RemoteProxyRetryClock
    ) async -> NativeSSHControlMasterResetOutcome {
        let maximumAttempts = 3
        for attemptIndex in 0..<maximumAttempts {
            guard !Task.isCancelled else {
                return .deferred("control-master reset cancelled")
            }
            let attempt = await runResetAttempt(
                request: request,
                processRunner: processRunner
            )
            guard !Task.isCancelled else {
                return .deferred("control-master reset cancelled")
            }
            switch attempt {
            case .reset:
                return .reset
            case .ignored(let detail):
                return .ignored(detail)
            case .retry(let detail):
                guard attemptIndex + 1 < maximumAttempts else {
                    return .deferred(detail)
                }
                do {
                    try await clock.sleep(forMilliseconds: 2_000)
                } catch {
                    return .deferred(error.localizedDescription)
                }
            }
        }
        return .deferred("control-master reset deferred")
    }

    private nonisolated static func runResetAttempt(
        request: NativeSSHControlMasterCleanupRequest,
        processRunner: any RemoteSessionProcessRunning
    ) async -> ResetAttemptOutcome {
        let cancellation = RemoteProcessCancellationOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let invocation = request.processInvocation(
                        noOpExitStatus:
                            NativeSSHControlMasterCleanupRequest.resetSkippedExitStatus
                    )
                    let processRequest = RemoteProcessRequest(
                        executable: invocation.executableURL.path,
                        arguments: invocation.arguments,
                        environment: request.environment,
                        timeout: 5
                    )
                    do {
                        let result = try processRunner.run(
                            processRequest,
                            operation: cancellation
                        )
                        let detail = bestErrorLine(
                            stderr: result.stderr,
                            stdout: result.stdout
                        ) ?? "ssh exited \(result.status)"
                        if result.status == 0 {
                            continuation.resume(returning: .reset)
                        } else if [
                            NativeSSHControlMasterCleanupRequest.retryExitStatus,
                            NativeSSHControlMasterCleanupRequest.resetSkippedExitStatus,
                        ].contains(result.status) {
                            continuation.resume(returning: .retry(detail))
                        } else {
                            continuation.resume(returning: .ignored(detail))
                        }
                    } catch {
                        continuation.resume(returning: .ignored(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
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

private enum ResetAttemptOutcome: Sendable {
    case reset
    case retry(String)
    case ignored(String)
}

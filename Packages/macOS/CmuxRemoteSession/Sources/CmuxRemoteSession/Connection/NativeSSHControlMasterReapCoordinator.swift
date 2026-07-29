internal import CmuxCore
internal import CmuxFoundation
internal import CmuxRemoteWorkspace
internal import Foundation

/// Outcome of one broker-authorized inherited-ControlMaster reap.
enum NativeSSHControlMasterReapOutcome: Sendable, Equatable {
    case reaped(eventID: UUID)
    case deferred(String)
    case ignored(String)
}

/// Broker-owned state for disruptive inherited-ControlMaster reaps.
///
/// Authorization, metadata proof, process execution, and sibling invalidation
/// form one operation so no caller can prove one socket and exit another.
@MainActor
final class NativeSSHControlMasterReapCoordinator {
    private struct InFlightReap {
        let id: UUID
        let task: Task<NativeSSHControlMasterReapOutcome, Never>
    }

    private let sharingOptions: SSHConnectionSharingOptions
    private let processRunner: any RemoteSessionProcessRunning
    private let eventHub: NativeSSHControlMasterReapEventHub
    private let ownershipRegistry:
        any NativeSSHControlMasterOwnershipTracking
    private var leases: [
        UUID: [
            NativeSSHControlMasterReapLeaseKey:
                WorkspaceRemoteConfiguration
        ]
    ] = [:]
    private var inFlightReaps: [String: InFlightReap] = [:]

    nonisolated init(
        sharingOptions: SSHConnectionSharingOptions,
        processRunner: any RemoteSessionProcessRunning,
        eventHub: NativeSSHControlMasterReapEventHub,
        ownershipRegistry: any NativeSSHControlMasterOwnershipTracking
    ) {
        self.sharingOptions = sharingOptions
        self.processRunner = processRunner
        self.eventHub = eventHub
        self.ownershipRegistry = ownershipRegistry
    }

    func retainWorkspace(
        _ configuration: WorkspaceRemoteConfiguration,
        ownerWorkspaceID: UUID,
        key: NativeSSHControlMasterReapLeaseKey
    ) {
        var ownerLeases = leases[ownerWorkspaceID] ?? [:]
        ownerLeases[key] = configuration
        leases[ownerWorkspaceID] = ownerLeases
    }

    func releaseWorkspace(
        ownerWorkspaceID: UUID,
        generation: UUID,
        key: NativeSSHControlMasterReapLeaseKey
    ) {
        guard var ownerLeases = leases[ownerWorkspaceID],
              ownerLeases[key]?.sshControlMasterLeaseGeneration ==
                generation else {
            return
        }
        ownerLeases.removeValue(forKey: key)
        if ownerLeases.isEmpty {
            leases.removeValue(forKey: ownerWorkspaceID)
        } else {
            leases[ownerWorkspaceID] = ownerLeases
        }
    }

    func reap(
        for configuration: WorkspaceRemoteConfiguration,
        resolvedControlPath: String,
        metadataProbeCommand: String
    ) async -> NativeSSHControlMasterReapOutcome {
        guard let ownerWorkspaceID = configuration.ownerWorkspaceID,
              let generation =
              configuration.sshControlMasterLeaseGeneration,
              let key = NativeSSHControlMasterReapLeaseKey(
                  configuration: configuration,
                  sharingOptions: sharingOptions
              ),
              ownsLease(
                  ownerWorkspaceID: ownerWorkspaceID,
                  generation: generation,
                  key: key
              ) else {
            return .ignored(
                "workspace no longer owns this cmux SSH master"
            )
        }
        guard !resolvedControlPath.contains("%"),
              sharingOptions.cmuxOwnedControlPath(in: [
                  "ControlMaster=auto",
                  "ControlPath=\(resolvedControlPath)",
              ]) == resolvedControlPath else {
            return .ignored(
                "could not identify the cmux SSH master socket"
            )
        }
        if let inFlight = inFlightReaps[resolvedControlPath] {
            return await inFlight.task.value
        }
        guard let lease = NativeSSHControlMasterLeaseIdentity(
            configuration: configuration
        ),
              ownershipRegistry.retain(
                  controlPath: resolvedControlPath,
                  lease: lease
              ) else {
            return .deferred(
                "resolved SSH master ownership is busy in another cmux process"
            )
        }
        guard let authorization = ownershipRegistry.beginRecovery(
            controlPath: resolvedControlPath
        ) else {
            return .deferred(
                "resolved SSH master is in use by another cmux process " +
                    "or foreground authentication"
            )
        }

        let resolver = NativeSSHControlPathResolver(
            sharingOptions: sharingOptions
        )
        let resolvedOptions = resolver.replacingControlPath(
            in: sharingOptions.mergingDefaults(
                into: configuration.sshOptions
            ),
            with: resolvedControlPath
        )
        let probeRequest = RemoteProcessRequest(
            executable: "/usr/bin/ssh",
            arguments: configuration.batchSSHCommandArguments(
                command: metadataProbeCommand,
                effectiveSSHOptions: resolvedOptions
            ),
            environment: configuration.sshProcessEnvironment,
            timeout: 6
        )
        let exitRequest = RemoteProcessRequest(
            executable: "/usr/bin/ssh",
            arguments: RemoteControlMasterCleanup().cleanupArguments(
                configuration: configuration,
                sshOptionsOverride: resolvedOptions
            ),
            environment: configuration.sshProcessEnvironment,
            timeout: 5
        )
        let reapID = UUID()
        let processRunner = self.processRunner
        let eventHub = self.eventHub
        let task: Task<
            NativeSSHControlMasterReapOutcome,
            Never
        > = Task {
            defer { authorization.release() }
            let attempt = await Self.runReap(
                metadataProbeRequest: probeRequest,
                exitRequest: exitRequest,
                processRunner: processRunner
            )
            switch attempt {
            case .reaped:
                let eventID = await eventHub.emit(
                    controlPath: resolvedControlPath
                )
                return .reaped(eventID: eventID)
            case .deferred(let detail):
                return .deferred(detail)
            case .ignored(let detail):
                return .ignored(detail)
            }
        }
        inFlightReaps[resolvedControlPath] = InFlightReap(
            id: reapID,
            task: task
        )
        let outcome = await task.value
        if inFlightReaps[resolvedControlPath]?.id == reapID {
            inFlightReaps.removeValue(forKey: resolvedControlPath)
        }
        return outcome
    }

    private func ownsLease(
        ownerWorkspaceID: UUID,
        generation: UUID,
        key: NativeSSHControlMasterReapLeaseKey
    ) -> Bool {
        leases[ownerWorkspaceID]?[key]?
            .sshControlMasterLeaseGeneration == generation
    }

    @concurrent
    private static func runReap(
        metadataProbeRequest: RemoteProcessRequest,
        exitRequest: RemoteProcessRequest,
        processRunner: any RemoteSessionProcessRunning
    ) async -> ReapAttemptOutcome {
        let cancellation = RemoteProcessCancellationOperation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                return .deferred("control-master reap cancelled")
            }
            do {
                let probe = try processRunner.run(
                    metadataProbeRequest,
                    operation: cancellation
                )
                guard probe.status == 0 else {
                    let detail = bestErrorLine(
                        stderr: probe.stderr,
                        stdout: probe.stdout
                    ) ?? "ssh exited \(probe.status)"
                    return probe.status == 64
                        ? .ignored("relay metadata did not match")
                        : .deferred(
                            "could not verify relay metadata: \(detail)"
                        )
                }
                guard !Task.isCancelled else {
                    return .deferred("control-master reap cancelled")
                }
                let exit = try processRunner.run(
                    exitRequest,
                    operation: cancellation
                )
                guard exit.status == 0 else {
                    let detail = bestErrorLine(
                        stderr: exit.stderr,
                        stdout: exit.stdout
                    ) ?? "ssh exited \(exit.status)"
                    return .ignored(
                        "control-master exit failed: \(detail)"
                    )
                }
                return .reaped
            } catch {
                return .deferred(error.localizedDescription)
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
                    !$0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                }) {
                return line.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
        }
        return nil
    }
}

private enum ReapAttemptOutcome: Sendable {
    case reaped
    case deferred(String)
    case ignored(String)
}

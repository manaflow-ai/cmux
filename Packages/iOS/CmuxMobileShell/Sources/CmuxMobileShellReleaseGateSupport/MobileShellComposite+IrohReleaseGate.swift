#if DEBUG
public import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
public import Foundation
import OSLog
public import CmuxMobileShell

private let mobileIrohReleaseGateProbeLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "iroh-release-gate-probe"
)

extension MobileShellComposite {
    /// Exercises the current authenticated Iroh session without retaining user data.
    ///
    /// The probe sends a host-status request, round-trips a process-unique marker
    /// through the selected terminal, renames then restores one workspace, and
    /// verifies representative event, notification, chat, and artifact RPCs.
    /// It is compiled only in Debug builds and is activated by the simulator E2E
    /// driver rather than product UI.
    ///
    /// - Parameter marker: An opaque ASCII marker unique to this gate run.
    /// - Returns: Credential-free proof that all operations succeeded.
    /// - Throws: ``MobileIrohReleaseGateProbeFailure`` when an invariant fails.
    public func runIrohReleaseGateProbe(
        marker: String,
        scenario: MobileIrohReleaseGateScenario = .standard,
        soakDurationSeconds: Int = 0,
        endpointIdentity: @escaping @Sendable () async -> CmxIrohPeerIdentity? = { nil },
        relayCredentialExpiry: @escaping @Sendable () async -> Date? = { nil }
    ) async throws -> MobileIrohReleaseGateProbeResult {
        guard connectionState == .connected,
              activeRoute?.kind == .iroh,
              let remoteClient else {
            throw MobileIrohReleaseGateProbeFailure.unauthenticatedIrohSession
        }

        mobileIrohReleaseGateProbeLog.info("probe stage=host_status state=begin")
        let statusData: Data
        do {
            let authenticated = try await remoteClient.sendRequestAndAuthenticatedHostStatus(
                MobileCoreRPCClient.requestData(method: "workspace.list", params: [:])
            )
            statusData = authenticated.hostStatusResponse
        } catch {
            throw MobileIrohReleaseGateProbeFailure.hostStatusRejected
        }
        guard let status = try? MobileHostStatusResponse.decode(statusData),
              status.macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              status.macInstanceTag?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw MobileIrohReleaseGateProbeFailure.hostStatusRejected
        }
        mobileIrohReleaseGateProbeLog.info("probe stage=host_status state=completed")

        guard let workspace = selectedWorkspace,
              workspace.actionCapabilities.supportsWorkspaceActions,
              !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileIrohReleaseGateProbeFailure.workspaceMutationUnavailable
        }
        guard let terminalID = selectedTerminalID?.rawValue else {
            throw MobileIrohReleaseGateProbeFailure.terminalUnavailable
        }
        var relayCredentialRolloverVerified = false
        var endpointContinuityVerified = false
        var connectionContinuityVerified = false
        var controlStreamContinuityVerified = false
        var independentEventsContinuityVerified = false
        var artifactLaneVerified = false
        var unrefreshedExpiryDisconnectVerified = false

        switch scenario {
        case .standard:
            try await verifyReversibleWorkspaceRename(
                workspace: workspace,
                marker: marker
            )
            try await verifyTerminalRoundTrip(
                surfaceID: terminalID,
                marker: marker
            )
            try await verifyIndependentEvents(
                client: remoteClient,
                marker: marker
            )
        case .relayRollover:
            let continuity = try await verifyRelayCredentialRollover(
                client: remoteClient,
                workspace: workspace,
                surfaceID: terminalID,
                marker: marker,
                soakDurationSeconds: soakDurationSeconds,
                endpointIdentity: endpointIdentity,
                relayCredentialExpiry: relayCredentialExpiry
            )
            relayCredentialRolloverVerified = continuity.relayCredentialRolloverVerified
            endpointContinuityVerified = continuity.endpointContinuityVerified
            connectionContinuityVerified = continuity.connectionContinuityVerified
            controlStreamContinuityVerified = continuity.controlStreamContinuityVerified
            independentEventsContinuityVerified = continuity.independentEventsContinuityVerified
            artifactLaneVerified = continuity.artifactLaneVerified
        case .relayExpiry:
            try await verifyReversibleWorkspaceRename(
                workspace: workspace,
                marker: marker
            )
            try await verifyTerminalRoundTrip(
                surfaceID: terminalID,
                marker: marker
            )
            try await verifyIndependentEvents(
                client: remoteClient,
                marker: marker
            )
        }
        mobileIrohReleaseGateProbeLog.info("probe stage=workspace_mutation state=completed")
        mobileIrohReleaseGateProbeLog.info("probe stage=terminal_round_trip state=completed")
        mobileIrohReleaseGateProbeLog.info("probe stage=independent_events state=completed")
        mobileIrohReleaseGateProbeLog.info("probe stage=notification_reconcile state=begin")
        try await verifyNotificationReconcile(client: remoteClient)
        mobileIrohReleaseGateProbeLog.info("probe stage=notification_reconcile state=completed")
        mobileIrohReleaseGateProbeLog.info("probe stage=chat_sessions state=begin")
        try await verifyChatSessions(
            client: remoteClient,
            workspaceID: workspace.rpcWorkspaceID.rawValue
        )
        mobileIrohReleaseGateProbeLog.info("probe stage=chat_sessions state=completed")
        mobileIrohReleaseGateProbeLog.info("probe stage=artifact_scan_count state=begin")
        try await verifyArtifactScanCount(
            client: remoteClient,
            workspaceID: workspace.rpcWorkspaceID.rawValue,
            surfaceID: terminalID
        )
        mobileIrohReleaseGateProbeLog.info("probe stage=artifact_scan_count state=completed")

        if scenario == .relayExpiry {
            unrefreshedExpiryDisconnectVerified = try await verifyUnrefreshedRelayExpiry(
                client: remoteClient,
                endpointIdentity: endpointIdentity,
                relayCredentialExpiry: relayCredentialExpiry
            )
        }

        return MobileIrohReleaseGateProbeResult(
            hostStatusVerified: true,
            terminalRoundTripVerified: true,
            workspaceMutationVerified: true,
            independentEventsVerified: true,
            notificationReconcileVerified: true,
            chatSessionsVerified: true,
            artifactScanCountVerified: true,
            relayCredentialRolloverVerified: relayCredentialRolloverVerified,
            endpointContinuityVerified: endpointContinuityVerified,
            connectionContinuityVerified: connectionContinuityVerified,
            controlStreamContinuityVerified: controlStreamContinuityVerified,
            independentEventsContinuityVerified: independentEventsContinuityVerified,
            artifactLaneVerified: artifactLaneVerified,
            unrefreshedExpiryDisconnectVerified: unrefreshedExpiryDisconnectVerified,
            soakDurationSeconds: scenario == .relayRollover ? soakDurationSeconds : 0
        )
    }

    private struct RelayRolloverContinuity {
        let relayCredentialRolloverVerified: Bool
        let endpointContinuityVerified: Bool
        let connectionContinuityVerified: Bool
        let controlStreamContinuityVerified: Bool
        let independentEventsContinuityVerified: Bool
        let artifactLaneVerified: Bool
    }

    private func verifyRelayCredentialRollover(
        client: MobileCoreRPCClient,
        workspace: MobileWorkspacePreview,
        surfaceID: String,
        marker: String,
        soakDurationSeconds: Int,
        endpointIdentity: @escaping @Sendable () async -> CmxIrohPeerIdentity?,
        relayCredentialExpiry: @escaping @Sendable () async -> Date?
    ) async throws -> RelayRolloverContinuity {
        guard soakDurationSeconds >= 330,
              let endpointBefore = await endpointIdentity(),
              let credentialExpiryBefore = await relayCredentialExpiry(),
              let connectionBefore = await client.transportContinuityID() else {
            throw MobileIrohReleaseGateProbeFailure.continuityEvidenceUnavailable
        }

        let streamID = "iroh-release-gate-\(marker.suffix(32))"
        let eventMarker = "cmux Iroh gate \(marker.suffix(8))"
        let subscribe = try MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: [
                "stream_id": streamID,
                "topics": ["workspace.updated"],
            ]
        )
        let subscribeData = try await client.sendRequest(subscribe)
        guard MobileIrohReleaseGateResponseValidator.independentEventSubscription(
            subscribeData,
            expectedStreamID: streamID,
            expectedAlreadySubscribed: false
        ) else {
            throw MobileIrohReleaseGateProbeFailure.independentEventsContinuityFailed
        }

        let artifactPath = "/tmp/cmux-iroh-gate-\(marker.suffix(24)).bin"
        // noq's pinned default per-stream receive window is 1.25 MB. Keeping a
        // 32 MB prefix unread guarantees the sender remains flow-controlled,
        // rather than letting a fully buffered payload masquerade as a live
        // post-rollover artifact lane.
        let artifactPrefixByteCount = 32 * 1_024 * 1_024
        let artifactSuffix = Data("CMUX_IROH_ARTIFACT_\(marker.suffix(24))".utf8)
        let artifactTotalByteCount = artifactPrefixByteCount + artifactSuffix.count
        let artifactSuffixText = String(decoding: artifactSuffix, as: UTF8.self)
        let artifactPreparation = MobileIrohReleaseGateArtifactPreparation.make(
            path: artifactPath,
            suffixText: artifactSuffixText,
            marker: marker
        )
        mobileIrohReleaseGateProbeLog.info("probe stage=artifact_prepare state=begin")
        var terminalIterator = terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        await submitTerminalRawInput(
            Data(artifactPreparation.command.utf8),
            surfaceID: surfaceID
        )
        let artifactCompletionMarker = Data(artifactPreparation.completionMarker.utf8)
        var terminalBytes = Data()
        var sawArtifactCompletion = false
        while let chunk = await terminalIterator.next() {
            terminalOutputDidProcess(
                surfaceID: surfaceID,
                streamToken: chunk.streamToken
            )
            terminalBytes.append(chunk.data)
            if terminalBytes.range(of: artifactCompletionMarker) != nil {
                sawArtifactCompletion = true
                break
            }
            if terminalBytes.count > 65_536 {
                terminalBytes.removeFirst(terminalBytes.count - 65_536)
            }
        }
        guard sawArtifactCompletion else {
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_prepare state=failed reason=command_not_completed"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactCommandNotCompleted
        }
        mobileIrohReleaseGateProbeLog.info("probe stage=artifact_prepare state=completed")

        mobileIrohReleaseGateProbeLog.info("probe stage=artifact_readiness state=begin")
        let readiness: ArtifactReadiness
        do {
            readiness = try await waitForArtifact(
                client: client,
                workspaceID: workspace.rpcWorkspaceID.rawValue,
                surfaceID: surfaceID,
                path: artifactPath,
                expectedSize: Int64(artifactTotalByteCount)
            )
        } catch {
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_readiness state=failed reason=rpc"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactReadinessRPCFailed
        }
        switch readiness {
        case .ready:
            mobileIrohReleaseGateProbeLog.info(
                "probe stage=artifact_readiness state=completed"
            )
        case .scanPathMissing:
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_readiness state=failed reason=scan_path_missing"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactScanPathMissing
        case .statSizeMismatch:
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_readiness state=failed reason=stat_size_mismatch"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactStatSizeMismatch
        }
        let descriptorData: Data
        do {
            let descriptorRequest = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.artifact.fetch",
                params: [
                    "workspace_id": workspace.rpcWorkspaceID.rawValue,
                    "surface_id": surfaceID,
                    "path": artifactPath,
                    "transport": "iroh_artifact_v1",
                ]
            )
            descriptorData = try await client.sendRequest(descriptorRequest)
        } catch {
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_descriptor state=failed reason=rpc"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactDescriptorRPCFailed
        }
        guard let descriptor = MobileIrohReleaseGateResponseValidator.artifactLaneDescriptor(
            descriptorData
        ), descriptor.totalSize == Int64(artifactTotalByteCount) else {
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_descriptor state=failed"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactDescriptorInvalid
        }
        let artifactConnection: any MobileArtifactLaneConnection
        do {
            artifactConnection = try await client.openArtifactLane(
                resourceID: descriptor.resourceID,
                offset: 0
            )
        } catch {
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_lane_open state=failed"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactLaneOpenFailed
        }
        let initialArtifactByte: Data?
        do {
            initialArtifactByte = try await artifactConnection.receive(maximumByteCount: 1)
        } catch {
            await artifactConnection.close()
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_lane_first_byte state=failed reason=read"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactLaneReadFailed
        }
        guard initialArtifactByte == Data([0]) else {
            await artifactConnection.close()
            await cleanUpRelayRolloverPreparation(
                client: client,
                streamID: streamID,
                artifactPath: artifactPath,
                surfaceID: surfaceID
            )
            mobileIrohReleaseGateProbeLog.error(
                "probe stage=artifact_lane_first_byte state=failed"
            )
            throw MobileIrohReleaseGateProbeFailure.artifactLaneInitialByteMismatch
        }

        do {
            var remaining = soakDurationSeconds
            while remaining > 0 {
                let interval = min(15, remaining)
                try await Task.sleep(for: .seconds(interval))
                let heartbeat = try MobileCoreRPCClient.requestData(
                    method: "workspace.list",
                    params: [:]
                )
                _ = try await client.sendRequest(heartbeat)
                remaining -= interval
            }

            guard let endpointAfter = await endpointIdentity(),
                  let credentialExpiryAfter = await relayCredentialExpiry(),
                  let connectionAfter = await client.transportContinuityID(),
                  endpointAfter == endpointBefore,
                  connectionAfter == connectionBefore,
                  credentialExpiryAfter > credentialExpiryBefore else {
                throw MobileIrohReleaseGateProbeFailure.relayRolloverFailed
            }

            let postMarker = "\(marker)_POST_ROLLOVER"
            await submitTerminalRawInput(
                Data("printf '\\n%s\\n' '\(postMarker)'\n".utf8),
                surfaceID: surfaceID
            )
            let postMarkerData = Data(postMarker.utf8)
            terminalBytes.removeAll(keepingCapacity: true)
            var sawPostMarker = false
            while let chunk = await terminalIterator.next() {
                terminalOutputDidProcess(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
                terminalBytes.append(chunk.data)
                if terminalBytes.range(of: postMarkerData) != nil {
                    sawPostMarker = true
                    break
                }
                if terminalBytes.count > 65_536 {
                    terminalBytes.removeFirst(terminalBytes.count - 65_536)
                }
            }
            guard sawPostMarker else {
                throw MobileIrohReleaseGateProbeFailure.controlStreamContinuityFailed
            }

            let reassertData = try await client.sendRequest(subscribe)
            guard MobileIrohReleaseGateResponseValidator.independentEventSubscription(
                reassertData,
                expectedStreamID: streamID,
                expectedAlreadySubscribed: true
            ) else {
                throw MobileIrohReleaseGateProbeFailure.independentEventsContinuityFailed
            }
            try await verifyFreshWorkspaceEvent(
                client: client,
                streamID: streamID,
                workspace: workspace,
                temporaryName: eventMarker
            )
            try await restoreWorkspace(workspace)

            var receivedArtifactByteCount = 1
            var receivedArtifactTail = Data()
            do {
                while let chunk = try await artifactConnection.receive(
                    maximumByteCount: 64 * 1_024
                ) {
                    receivedArtifactByteCount += chunk.count
                    guard receivedArtifactByteCount <= artifactTotalByteCount else {
                        throw MobileIrohReleaseGateProbeFailure.artifactLaneOverrun
                    }
                    receivedArtifactTail.append(chunk)
                    if receivedArtifactTail.count > artifactSuffix.count {
                        receivedArtifactTail.removeFirst(
                            receivedArtifactTail.count - artifactSuffix.count
                        )
                    }
                }
            } catch let failure as MobileIrohReleaseGateProbeFailure {
                throw failure
            } catch {
                throw MobileIrohReleaseGateProbeFailure.artifactLaneReadFailed
            }
            guard receivedArtifactByteCount == artifactTotalByteCount else {
                throw MobileIrohReleaseGateProbeFailure.artifactLaneTruncated
            }
            guard receivedArtifactTail == artifactSuffix else {
                throw MobileIrohReleaseGateProbeFailure.artifactLaneTailMismatch
            }

            await artifactConnection.close()
            await bestEffortEventUnsubscribe(client: client, streamID: streamID)
            await submitTerminalRawInput(
                Data("rm -f '\(artifactPath)'\n".utf8),
                surfaceID: surfaceID
            )
            return RelayRolloverContinuity(
                relayCredentialRolloverVerified: true,
                endpointContinuityVerified: true,
                connectionContinuityVerified: true,
                controlStreamContinuityVerified: true,
                independentEventsContinuityVerified: true,
                artifactLaneVerified: true
            )
        } catch {
            await artifactConnection.close()
            await bestEffortEventUnsubscribe(client: client, streamID: streamID)
            await restoreWorkspaceBestEffort(workspace)
            await submitTerminalRawInput(
                Data("rm -f '\(artifactPath)'\n".utf8),
                surfaceID: surfaceID
            )
            if let failure = error as? MobileIrohReleaseGateProbeFailure {
                throw failure
            }
            throw MobileIrohReleaseGateProbeFailure.relayRolloverFailed
        }
    }

    private func verifyUnrefreshedRelayExpiry(
        client: MobileCoreRPCClient,
        endpointIdentity: @escaping @Sendable () async -> CmxIrohPeerIdentity?,
        relayCredentialExpiry: @escaping @Sendable () async -> Date?
    ) async throws -> Bool {
        guard let endpointBefore = await endpointIdentity(),
              let credentialExpiryBefore = await relayCredentialExpiry(),
              await client.transportContinuityID() != nil,
              let closureObservation = await client.transportClosureObservation() else {
            throw MobileIrohReleaseGateProbeFailure.continuityEvidenceUnavailable
        }
        let deadline = credentialExpiryBefore.addingTimeInterval(20)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(5))
            do {
                let heartbeat = try MobileCoreRPCClient.requestData(
                    method: "workspace.list",
                    params: [:]
                )
                _ = try await client.sendRequest(heartbeat)
            } catch let error as MobileShellConnectionError {
                guard Date() >= credentialExpiryBefore.addingTimeInterval(-2),
                      case .connectionClosed = error,
                      await endpointIdentity() == endpointBefore,
                      await relayCredentialExpiry() == credentialExpiryBefore,
                      await transportDidClose(
                          observation: closureObservation,
                          client: client
                      ) else {
                    throw MobileIrohReleaseGateProbeFailure.unrefreshedCredentialDidNotDisconnect
                }
                return true
            } catch {
                throw MobileIrohReleaseGateProbeFailure.unrefreshedCredentialDidNotDisconnect
            }
        }
        throw MobileIrohReleaseGateProbeFailure.unrefreshedCredentialDidNotDisconnect
    }

    private func verifyFreshWorkspaceEvent(
        client: MobileCoreRPCClient,
        streamID: String,
        workspace: MobileWorkspacePreview,
        temporaryName: String
    ) async throws {
        let eventStream = await client.subscribe(to: ["workspace.updated"])
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in eventStream {
                    try Task.checkCancellation()
                    if event.topic == "workspace.updated", event.streamID == streamID {
                        return true
                    }
                }
                return false
            }
            // Give the structured listener a scheduling opportunity before the
            // mutation. A new local stream cannot contain pre-rollover events.
            await Task.yield()
            try await renameWorkspaceForEvent(
                workspace: workspace,
                temporaryName: temporaryName
            )
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw MobileIrohReleaseGateProbeFailure.independentEventsContinuityFailed
            }
            defer { group.cancelAll() }
            guard try await group.next() == true else {
                throw MobileIrohReleaseGateProbeFailure.independentEventsContinuityFailed
            }
        }
    }

    private func transportDidClose(
        observation: CmxTransportClosureObservation,
        client: MobileCoreRPCClient
    ) async -> Bool {
        await observation.waitUntilClosed()
        return await client.transportContinuityID() == nil
    }

    private enum ArtifactReadiness {
        case ready
        case scanPathMissing
        case statSizeMismatch
    }

    private func waitForArtifact(
        client: MobileCoreRPCClient,
        workspaceID: String,
        surfaceID: String,
        path: String,
        expectedSize: Int64
    ) async throws -> ArtifactReadiness {
        let scanRequest = try MobileCoreRPCClient.requestData(
            method: "mobile.terminal.artifact.scan",
            params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
            ]
        )
        let statRequest = try MobileCoreRPCClient.requestData(
            method: "mobile.terminal.artifact.stat",
            params: [
                "workspace_id": workspaceID,
                "surface_id": surfaceID,
                "path": path,
            ]
        )
        var sawExpectedPath = false
        var consecutiveStableObservations = 0
        for _ in 0 ..< 100 {
            let scanResponse = try await client.sendRequest(scanRequest)
            if MobileIrohReleaseGateResponseValidator.artifactPath(
                scanResponse,
                expectedPath: path
            ) {
                sawExpectedPath = true
                let statResponse = try await client.sendRequest(statRequest)
                if MobileIrohReleaseGateResponseValidator.artifactStat(
                    statResponse,
                    expectedSize: expectedSize
                ) {
                    consecutiveStableObservations += 1
                    if consecutiveStableObservations
                        >= MobileIrohReleaseGateArtifactPreparation.requiredStableStatObservations {
                        return .ready
                    }
                } else {
                    consecutiveStableObservations = 0
                }
            } else {
                consecutiveStableObservations = 0
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return sawExpectedPath ? .statSizeMismatch : .scanPathMissing
    }

    private func cleanUpRelayRolloverPreparation(
        client: MobileCoreRPCClient,
        streamID: String,
        artifactPath: String,
        surfaceID: String
    ) async {
        await bestEffortEventUnsubscribe(client: client, streamID: streamID)
        await submitTerminalRawInput(
            Data("rm -f '\(artifactPath)'\n".utf8),
            surfaceID: surfaceID
        )
    }

    private func renameWorkspaceForEvent(
        workspace: MobileWorkspacePreview,
        temporaryName: String
    ) async throws {
        let result = await renameWorkspace(id: workspace.id, title: temporaryName)
        guard case .success = result,
              workspaces.first(where: { $0.id == workspace.id })?.name == temporaryName else {
            throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
        }
    }

    private func restoreWorkspace(_ workspace: MobileWorkspacePreview) async throws {
        let result = await renameWorkspace(id: workspace.id, title: workspace.name)
        guard case .success = result,
              workspaces.first(where: { $0.id == workspace.id })?.name == workspace.name else {
            throw MobileIrohReleaseGateProbeFailure.workspaceRestorationFailed
        }
    }

    private func restoreWorkspaceBestEffort(_ workspace: MobileWorkspacePreview) async {
        _ = try? await restoreWorkspace(workspace)
    }

    private func verifyIndependentEvents(
        client: MobileCoreRPCClient,
        marker: String
    ) async throws {
        let streamID = "iroh-release-gate-\(marker.suffix(32))"
        do {
            let subscribe = try MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": streamID,
                    "topics": ["workspace.updated"],
                ]
            )
            let subscribeData = try await client.sendRequest(subscribe)
            guard MobileIrohReleaseGateResponseValidator.independentEventSubscription(
                subscribeData,
                expectedStreamID: streamID
            ) else {
                throw MobileIrohReleaseGateProbeFailure.independentEventsFailed
            }

            let unsubscribe = try MobileCoreRPCClient.requestData(
                method: "mobile.events.unsubscribe",
                params: ["stream_id": streamID]
            )
            let unsubscribeData = try await client.sendRequest(unsubscribe)
            guard MobileIrohReleaseGateResponseValidator.independentEventUnsubscription(
                unsubscribeData,
                expectedStreamID: streamID
            ) else {
                throw MobileIrohReleaseGateProbeFailure.independentEventsFailed
            }
        } catch {
            await bestEffortEventUnsubscribe(client: client, streamID: streamID)
            throw MobileIrohReleaseGateProbeFailure.independentEventsFailed
        }
    }

    private func bestEffortEventUnsubscribe(
        client: MobileCoreRPCClient,
        streamID: String
    ) async {
        guard let request = try? MobileCoreRPCClient.requestData(
            method: "mobile.events.unsubscribe",
            params: ["stream_id": streamID]
        ) else { return }
        _ = try? await client.sendRequest(request)
    }

    private func verifyNotificationReconcile(
        client: MobileCoreRPCClient
    ) async throws {
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "notification.reconcile",
                params: [
                    "delivered_ids": [],
                    "client_id": "iroh-release-gate",
                ]
            )
            let response = try await client.sendRequest(request)
            guard MobileIrohReleaseGateResponseValidator.notificationReconcile(response) else {
                throw MobileIrohReleaseGateProbeFailure.notificationReconcileFailed
            }
        } catch {
            throw MobileIrohReleaseGateProbeFailure.notificationReconcileFailed
        }
    }

    private func verifyChatSessions(
        client: MobileCoreRPCClient,
        workspaceID: String
    ) async throws {
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.chat.sessions",
                params: ["workspace_id": workspaceID]
            )
            let response = try await client.sendRequest(request)
            guard MobileIrohReleaseGateResponseValidator.chatSessions(response) else {
                throw MobileIrohReleaseGateProbeFailure.chatSessionsFailed
            }
        } catch {
            throw MobileIrohReleaseGateProbeFailure.chatSessionsFailed
        }
    }

    private func verifyArtifactScanCount(
        client: MobileCoreRPCClient,
        workspaceID: String,
        surfaceID: String
    ) async throws {
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.artifact.scan",
                params: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                    "count_only": true,
                ]
            )
            let response = try await client.sendRequest(request)
            guard MobileIrohReleaseGateResponseValidator.artifactScanCount(response) else {
                throw MobileIrohReleaseGateProbeFailure.artifactScanCountFailed
            }
        } catch {
            throw MobileIrohReleaseGateProbeFailure.artifactScanCountFailed
        }
    }

    private func verifyReversibleWorkspaceRename(
        workspace: MobileWorkspacePreview,
        marker: String
    ) async throws {
        let originalName = workspace.name
        let temporaryName = "cmux Iroh gate \(marker.suffix(8))"
        let renameResult = await renameWorkspace(id: workspace.id, title: temporaryName)
        guard case .success = renameResult else {
            throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
        }
        let mutationWasReflected = workspaces.first(where: {
            $0.id == workspace.id
        })?.name == temporaryName

        let restoreResult = await renameWorkspace(id: workspace.id, title: originalName)
        guard case .success = restoreResult,
              workspaces.first(where: { $0.id == workspace.id })?.name == originalName else {
            throw MobileIrohReleaseGateProbeFailure.workspaceRestorationFailed
        }
        guard mutationWasReflected else {
            throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
        }
    }

    private func verifyTerminalRoundTrip(
        surfaceID: String,
        marker: String
    ) async throws {
        let markerData = Data(marker.utf8)
        var received = Data()
        var iterator = terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

        await submitTerminalRawInput(
            Data("printf '\\n%s\\n' '\(marker)'\n".utf8),
            surfaceID: surfaceID
        )

        while let chunk = await iterator.next() {
            terminalOutputDidProcess(
                surfaceID: surfaceID,
                streamToken: chunk.streamToken
            )
            received.append(chunk.data)
            if received.range(of: markerData) != nil {
                return
            }
            if received.count > 65_536 {
                received.removeFirst(received.count - 65_536)
            }
        }
        throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed
    }
}
#endif

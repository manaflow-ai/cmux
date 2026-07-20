#if DEBUG
import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
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
        marker: String
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
        try await verifyReversibleWorkspaceRename(
            workspace: workspace,
            marker: marker
        )
        mobileIrohReleaseGateProbeLog.info("probe stage=workspace_mutation state=completed")

        guard let terminalID = selectedTerminalID?.rawValue else {
            throw MobileIrohReleaseGateProbeFailure.terminalUnavailable
        }
        try await verifyTerminalRoundTrip(
            surfaceID: terminalID,
            marker: marker
        )
        mobileIrohReleaseGateProbeLog.info("probe stage=terminal_round_trip state=completed")
        mobileIrohReleaseGateProbeLog.info("probe stage=independent_events state=begin")
        try await verifyIndependentEvents(
            client: remoteClient,
            marker: marker
        )
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

        return MobileIrohReleaseGateProbeResult(
            hostStatusVerified: true,
            terminalRoundTripVerified: true,
            workspaceMutationVerified: true,
            independentEventsVerified: true,
            notificationReconcileVerified: true,
            chatSessionsVerified: true,
            artifactScanCountVerified: true
        )
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

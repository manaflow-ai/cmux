#if DEBUG
import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    /// Exercises the current authenticated Iroh session without retaining user data.
    ///
    /// The probe sends a host-status request, round-trips a process-unique marker
    /// through the selected terminal, and renames then restores one workspace.
    /// It is compiled only in Debug builds and is activated by the simulator E2E
    /// driver rather than product UI.
    ///
    /// - Parameter marker: An opaque ASCII marker unique to this gate run.
    /// - Returns: Credential-free proof that all three operations succeeded.
    /// - Throws: ``MobileIrohReleaseGateProbeFailure`` when an invariant fails.
    public func runIrohReleaseGateProbe(
        marker: String
    ) async throws -> MobileIrohReleaseGateProbeResult {
        guard connectionState == .connected,
              activeRoute?.kind == .iroh,
              let remoteClient else {
            throw MobileIrohReleaseGateProbeFailure.unauthenticatedIrohSession
        }

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

        guard let workspace = selectedWorkspace,
              workspace.actionCapabilities.supportsWorkspaceActions,
              !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileIrohReleaseGateProbeFailure.workspaceMutationUnavailable
        }
        try await verifyReversibleWorkspaceRename(
            workspace: workspace,
            marker: marker
        )

        guard let terminalID = selectedTerminalID?.rawValue else {
            throw MobileIrohReleaseGateProbeFailure.terminalUnavailable
        }
        try await verifyTerminalRoundTrip(
            surfaceID: terminalID,
            marker: marker
        )

        return MobileIrohReleaseGateProbeResult(
            hostStatusVerified: true,
            terminalRoundTripVerified: true,
            workspaceMutationVerified: true
        )
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

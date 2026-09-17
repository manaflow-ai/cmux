#if DEBUG
import CmuxMobileRPC
public import CMUXMobileCore
public import CmuxMobileShell
import Foundation

extension MobileShellComposite {
    public func irohSoakConnection() async -> CmxTransportConnectionObservation? {
        guard hasActiveMacConnection, activeRoute?.kind == .iroh else { return nil }
        return await remoteClient?.transportConnectionObservation()
    }

    /// Identifies the live native connection so a successful redial cannot hide a drop.
    public func irohSoakConnectionID() async -> UInt64? {
        guard hasActiveMacConnection, activeRoute?.kind == .iroh else { return nil }
        return await remoteClient?.transportContinuityID()
    }

    /// Executes one deterministic usage step through the same actions as the app UI.
    /// - Parameters:
    ///   - cycle: Zero-based workload cycle; selects one of four fixed steps.
    ///   - marker: Unique terminal output marker for this cycle.
    /// - Returns: Names of operations whose postconditions passed.
    /// - Throws: A gate failure when navigation, terminal output or reconnection fails.
    public func runIrohSoakUsageStep(cycle: Int, marker: String) async throws -> [String] {
        guard let target = irohReleaseGateForegroundTarget() else {
            throw MobileIrohReleaseGateProbeFailure.workspaceMutationUnavailable
        }
        switch cycle % 4 {
        case 0:
            await refreshWorkspaces()
            await refreshNotificationFeed()
            guard let current = irohReleaseGateCurrentWorkspace(matching: target.workspace) else {
                throw MobileIrohReleaseGateProbeFailure.workspaceMutationUnavailable
            }
            selectedWorkspaceID = nil
            await openWorkspace(current.id)
            selectTerminalFromChrome(target.terminalID)
            guard selectedWorkspaceID == current.id, selectedTerminalID == target.terminalID else {
                throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
            }
            try await verifyTerminalRoundTrip(surfaceID: target.terminalID.rawValue, marker: marker + "_NAV")
            return ["workspace_navigation", "workspace_refresh", "notification_refresh"]
        case 1:
            // Exercise output backpressure and UTF-8 before requiring a fresh terminal result.
            await submitTerminalRawInput(
                Data("for i in {1..128}; do printf 'soak %s café 日本語 🔧\\n' \"$i\"; done\n".utf8),
                surfaceID: target.terminalID.rawValue
            )
            try await verifyTerminalRoundTrip(surfaceID: target.terminalID.rawValue, marker: marker + "_BURST")
            return ["unicode_output_burst"]
        case 2:
            let title = "cmux soak \(marker.suffix(16))"
            let created = await createWorkspaceRequest(spec: .init(title: title, workingDirectory: "/tmp"))
            guard case .success = created,
                  let scratch = workspaces.first(where: { $0.name == title }),
                  let terminal = scratch.terminals.first else {
                throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
            }
            do {
                await openWorkspace(scratch.id)
                selectTerminalFromChrome(terminal.id)
                guard selectedWorkspaceID == scratch.id else {
                    throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
                }
                try await verifyTerminalRoundTrip(surfaceID: terminal.id.rawValue, marker: marker + "_NEW")
            } catch {
                _ = await closeWorkspace(id: scratch.id)
                throw error
            }
            let closed = await closeWorkspace(id: scratch.id)
            guard case .success = closed,
                  let original = irohReleaseGateCurrentWorkspace(matching: target.workspace) else {
                throw MobileIrohReleaseGateProbeFailure.workspaceRestorationFailed
            }
            await openWorkspace(original.id)
            try await verifyTerminalRoundTrip(surfaceID: target.terminalID.rawValue, marker: marker + "_RESTORED")
            return ["workspace_create", "workspace_switch", "workspace_close", "terminal_after_restore"]
        default:
            guard cycle % 120 == 119 else {
                await refreshWorkspaces()
                try await verifyTerminalRoundTrip(surfaceID: target.terminalID.rawValue, marker: marker + "_REFRESH")
                return ["terminal_after_refresh"]
            }
            let before = await irohSoakConnectionID()
            // A retry on a healthy session deliberately reuses that session.
            // Exercise recovery by tearing down the test connection while
            // preserving its pairing, then invoke the shared retry action.
            disconnectLiveConnection()
            guard await retryActiveMacReconnect(stackUserID: nil, force: true) else {
                throw MobileIrohReleaseGateProbeFailure.soakReconnectFailed
            }
            guard let before, let after = await irohSoakConnectionID() else {
                throw MobileIrohReleaseGateProbeFailure.continuityEvidenceUnavailable
            }
            guard before != after else {
                throw MobileIrohReleaseGateProbeFailure.soakConnectionNotReplaced
            }
            _ = try await runIrohReleaseGateProbe(marker: marker + "_RECONNECTED")
            return ["forced_reconnect", "terminal_after_reconnect"]
        }
    }
}
#endif

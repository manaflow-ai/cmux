#if DEBUG
import CmuxMobileRPC
public import CMUXMobileCore
public import CmuxMobileShell
import Foundation

extension MobileShellComposite {
    public func irohSoakUIIdentity() -> (workspace: String, surface: String)? {
        guard let target = irohReleaseGateForegroundTarget() else { return nil }
        return (target.workspace.id.rawValue, target.terminalID.rawValue)
    }

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
    /// - Returns: Operation names and elapsed durations whose postconditions passed.
    /// - Throws: A gate failure when navigation, terminal output or reconnection fails.
    public func runIrohSoakUsageStep(cycle: Int, marker: String, terminalSession: MobileIrohReleaseGateTerminalSession? = nil) async throws -> [String: Double] {
        guard let target = irohReleaseGateForegroundTarget() else {
            throw MobileIrohReleaseGateProbeFailure.workspaceMutationUnavailable
        }
        switch cycle % 4 {
        case 0:
            let refreshStarted = ContinuousClock.now
            await refreshWorkspaces()
            let refreshSeconds = soakSeconds(refreshStarted)
            let notificationStarted = ContinuousClock.now
            await refreshNotificationFeed()
            let notificationSeconds = soakSeconds(notificationStarted)
            guard let current = irohReleaseGateCurrentWorkspace(matching: target.workspace) else {
                throw MobileIrohReleaseGateProbeFailure.workspaceMutationUnavailable
            }
            let navigationStarted = ContinuousClock.now
            selectedWorkspaceID = nil
            await openWorkspace(current.id)
            selectTerminalFromChrome(target.terminalID)
            guard selectedWorkspaceID == current.id, selectedTerminalID == target.terminalID else {
                throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
            }
            let navigationSeconds = soakSeconds(navigationStarted)
            try await verifyTerminalRoundTrip(surfaceID: target.terminalID.rawValue, marker: marker + "_NAV", session: terminalSession)
            return [
                "workspace_navigation": navigationSeconds,
                "workspace_refresh": refreshSeconds,
                "notification_refresh": notificationSeconds,
            ]
        case 1:
            // Exercise output backpressure and UTF-8 before requiring a fresh terminal result.
            let started = ContinuousClock.now
            await submitTerminalRawInput(
                Data("for i in {1..128}; do printf 'soak %s café 日本語 🔧\\n' \"$i\"; done\n".utf8),
                surfaceID: target.terminalID.rawValue
            )
            try await verifyTerminalRoundTrip(surfaceID: target.terminalID.rawValue, marker: marker + "_BURST", session: terminalSession)
            return ["unicode_output_burst": soakSeconds(started)]
        case 2:
            let title = "cmux soak \(marker.suffix(16))"
            let createStarted = ContinuousClock.now
            let created = await createWorkspaceRequest(spec: .init(title: title, workingDirectory: "/tmp"))
            guard case .success = created,
                  let scratch = workspaces.first(where: { $0.name == title }),
                  let terminal = scratch.terminals.first else {
                throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
            }
            let createSeconds = soakSeconds(createStarted)
            let switchStarted = ContinuousClock.now
            do {
                await openWorkspace(scratch.id)
                selectTerminalFromChrome(terminal.id)
                guard selectedWorkspaceID == scratch.id else {
                    throw MobileIrohReleaseGateProbeFailure.workspaceMutationFailed
                }
                try await verifyTerminalRoundTrip(surfaceID: terminal.id.rawValue, marker: marker + "_NEW", session: terminalSession)
            } catch {
                _ = await closeWorkspace(id: scratch.id)
                throw error
            }
            let switchSeconds = soakSeconds(switchStarted)
            let closeStarted = ContinuousClock.now
            let closed = await closeWorkspace(id: scratch.id)
            guard case .success = closed,
                  let original = irohReleaseGateCurrentWorkspace(matching: target.workspace) else {
                throw MobileIrohReleaseGateProbeFailure.workspaceRestorationFailed
            }
            let closeSeconds = soakSeconds(closeStarted)
            await openWorkspace(original.id)
            let terminalStarted = ContinuousClock.now
            try await verifyTerminalRoundTrip(surfaceID: target.terminalID.rawValue, marker: marker + "_RESTORED", session: terminalSession)
            return [
                "workspace_create": createSeconds,
                "workspace_switch": switchSeconds,
                "workspace_close": closeSeconds,
                "terminal_after_restore": soakSeconds(terminalStarted),
            ]
        default:
            guard cycle % 120 == 119 else {
                let started = ContinuousClock.now
                await refreshWorkspaces()
                try await verifyTerminalRoundTrip(surfaceID: target.terminalID.rawValue, marker: marker + "_REFRESH", session: terminalSession)
                return ["terminal_after_refresh": soakSeconds(started)]
            }
            let before = await irohSoakConnectionID()
            // A retry on a healthy session deliberately reuses that session.
            // Exercise recovery by tearing down the test connection while
            // preserving its pairing, then invoke the shared retry action.
            let reconnectStarted = ContinuousClock.now
            terminalSession?.reset()
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
            let reconnectSeconds = soakSeconds(reconnectStarted)
            let terminalStarted = ContinuousClock.now
            _ = try await runIrohReleaseGateProbe(marker: marker + "_RECONNECTED", terminalSession: terminalSession)
            return [
                "forced_reconnect": reconnectSeconds,
                "terminal_after_reconnect": soakSeconds(terminalStarted),
            ]
        }
    }

    private func soakSeconds(_ started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif

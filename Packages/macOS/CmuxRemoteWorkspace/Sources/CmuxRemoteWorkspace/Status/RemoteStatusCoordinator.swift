public import CmuxCore
public import Foundation
import Observation

/// Per-workspace owner of the publish-side remote-status apply logic: the six
/// bodies that fold a session's reported remote state into the workspace's
/// published status, sidebar banners, dedup-gated logs, and notifications.
///
/// This lifts the decision and bookkeeping bodies of the legacy `Workspace`
/// methods `applyRemoteConnectionStateUpdate(_:detail:target:)`,
/// `applyRemoteDaemonStatusUpdate(_:target:)`,
/// `applyRemoteProxyEndpointUpdate(_:)`, `applyRemoteHeartbeatUpdate(count:lastSeenAt:)`,
/// `applyRemoteDetectedSurfacePortsSnapshot(...)`, and the private
/// `clearRemoteDetectedSurfacePorts()`. The workspace keeps thin forwarders so
/// the `WorkspaceRemoteSessionHostAdapter` publish callbacks and the in-file
/// connect/disconnect callers still resolve.
///
/// The published remote-status stored state stays on the workspace (its `didSet`
/// Combine bridges must keep firing, and several fields are also reset on
/// connect/disconnect outside this slice); the coordinator reads and writes it,
/// the sidebar entries/log, the notification store, the slice-1 decision
/// helpers, and the browser-panel fan-out through ``RemoteStatusHosting``.
///
/// ## Isolation design
///
/// `@MainActor`, matching the legacy isolation exactly: every lifted body was a
/// plain method on the `@MainActor` `Workspace` class, so every read, every
/// published write, and every fan-out already ran on the main actor. The host
/// reference is weak (the workspace owns the coordinator), so there is no retain
/// cycle.
@MainActor
@Observable
public final class RemoteStatusCoordinator<Host: RemoteStatusHosting> {
    @ObservationIgnored
    private weak var host: Host?

    /// Creates a remote-status coordinator. Call ``attach(host:)`` at the
    /// composition point before any publish callback runs so the live-workspace
    /// reads and pushes resolve.
    public init() {}

    /// Injects the live-workspace seam. Set before any orchestration runs.
    public func attach(host: Host) {
        self.host = host
    }

    /// Folds a reported remote connection `state` into the workspace's published
    /// state, sidebar banner, dedup-gated log, and notification. Faithful lift of
    /// `Workspace.applyRemoteConnectionStateUpdate(_:detail:target:)`.
    public func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        guard let host else { return }
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(\.indicatesProxyOnlyRemoteError) ?? false
        let effectiveState = state.effectiveRemoteConnectionState(
            isProxyOnlyError: proxyOnlyError,
            preservesProxyFailureWhileSSHTerminalIsAlive: host.hostPreservesProxyFailureWhileSSHTerminalIsAlive,
            hasProxyOnlySidebarError: host.hostHasProxyOnlyRemoteSidebarError
        )

        host.hostRemoteConnectionState = effectiveState
        host.hostRemoteConnectionDetail = detail
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()

        if state == .suspended {
            let entryDetail = trimmedDetail ?? ""
            let strings = host.hostRemoteStatusStrings
            let entryValue = String(
                format: strings.suspendedStatusEntryFormat,
                locale: .current,
                target,
                entryDetail
            )
            host.hostSetRemoteStatusEntry(
                forKey: host.hostRemoteErrorStatusKey,
                value: entryValue,
                icon: "pause.circle"
            )
            let fingerprint = "suspended:\(entryDetail)"
            if host.hostRemoteLastErrorFingerprint != fingerprint {
                host.hostRemoteLastErrorFingerprint = fingerprint
                host.hostAppendRemoteSidebarLog(message: entryValue, level: .warning, source: "remote")
                host.hostAddRemoteNotification(
                    title: strings.suspendedNotificationTitle,
                    subtitle: target,
                    body: entryDetail,
                    cooldownKey: host.hostRemoteNotificationCooldownKey(target: target),
                    cooldownInterval: host.hostRemoteNotificationCooldown
                )
            }
            return
        }

        if let trimmedDetail, !trimmedDetail.isEmpty, (state == .error || proxyOnlyError) {
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            host.hostSetRemoteStatusEntry(
                forKey: host.hostRemoteErrorStatusKey,
                value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                icon: statusIcon
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if host.hostRemoteLastErrorFingerprint != fingerprint {
                host.hostRemoteLastErrorFingerprint = fingerprint
                host.hostAppendRemoteSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                host.hostAddRemoteNotification(
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail,
                    cooldownKey: host.hostRemoteNotificationCooldownKey(target: target),
                    cooldownInterval: host.hostRemoteNotificationCooldown
                )
            }
            return
        }

        if state == .connected {
            host.hostRemoveRemoteStatusEntry(forKey: host.hostRemoteErrorStatusKey)
            host.hostRemoteLastErrorFingerprint = nil
        }
    }

    /// Folds a reported daemon `status` into the workspace's published state,
    /// dedup-gated log, and browser fan-out. Faithful lift of
    /// `Workspace.applyRemoteDaemonStatusUpdate(_:target:)`.
    public func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        guard let host else { return }
        host.hostRemoteDaemonStatus = status
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            host.hostRemoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard host.hostRemoteLastDaemonErrorFingerprint != fingerprint else { return }
        host.hostRemoteLastDaemonErrorFingerprint = fingerprint
        host.hostAppendRemoteSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    /// Publishes a new proxy `endpoint`, fans it out to browser panels, and
    /// refreshes the browser status. Faithful lift of
    /// `Workspace.applyRemoteProxyEndpointUpdate(_:)`.
    public func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        guard let host else { return }
        host.hostRemoteProxyEndpoint = endpoint
        host.hostApplyRemoteProxyEndpointToBrowserPanels(endpoint)
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
    }

    /// Publishes a heartbeat `count` and `lastSeenAt`, then refreshes the browser
    /// status. Faithful lift of `Workspace.applyRemoteHeartbeatUpdate(count:lastSeenAt:)`.
    public func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        guard let host else { return }
        host.hostRemoteHeartbeatCount = max(0, count)
        host.hostRemoteLastHeartbeatAt = lastSeenAt
        host.hostApplyBrowserRemoteWorkspaceStatusToPanels()
    }

    /// Reconciles a detected-surface-ports snapshot into the per-surface
    /// listening-port map, the published port lists, and the port-conflict
    /// banner/log. Faithful lift of
    /// `Workspace.applyRemoteDetectedSurfacePortsSnapshot(...)`.
    public func applyRemoteDetectedSurfacePortsSnapshot(
        detectedByPanel: [UUID: [Int]],
        detected: [Int],
        forwarded: [Int],
        conflicts: [Int],
        target: String
    ) {
        guard let host else { return }
        let trackedSurfaceIds = Set(detectedByPanel.keys)
        for panelId in host.hostRemoteDetectedSurfaceIds.subtracting(trackedSurfaceIds) {
            host.hostRemoveSurfaceListeningPorts(forPanel: panelId)
        }
        host.hostRemoteDetectedSurfaceIds = trackedSurfaceIds

        for (panelId, ports) in detectedByPanel {
            if ports.isEmpty {
                host.hostRemoveSurfaceListeningPorts(forPanel: panelId)
            } else {
                host.hostSetSurfaceListeningPorts(ports, forPanel: panelId)
            }
        }

        host.hostRemoteDetectedPorts = detected
        host.hostRemoteForwardedPorts = forwarded
        host.hostRemotePortConflicts = conflicts
        host.hostRecomputeListeningPorts()

        if conflicts.isEmpty {
            host.hostRemoveRemoteStatusEntry(forKey: host.hostRemotePortConflictStatusKey)
            host.hostRemoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        host.hostSetRemoteStatusEntry(
            forKey: host.hostRemotePortConflictStatusKey,
            value: "SSH port conflicts (\(target)): \(conflictsList)",
            icon: "exclamationmark.triangle.fill"
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard host.hostRemoteLastPortConflictFingerprint != fingerprint else { return }
        host.hostRemoteLastPortConflictFingerprint = fingerprint
        host.hostAppendRemoteSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }

    /// Drops every tracked detected-surface listening-port entry and clears the
    /// tracked id set. Faithful lift of the private
    /// `Workspace.clearRemoteDetectedSurfacePorts()`.
    public func clearRemoteDetectedSurfacePorts() {
        guard let host else { return }
        for panelId in host.hostRemoteDetectedSurfaceIds {
            host.hostRemoveSurfaceListeningPorts(forPanel: panelId)
        }
        host.hostRemoteDetectedSurfaceIds.removeAll()
    }
}

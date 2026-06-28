public import Foundation

/// Per-workspace owner of the pending remote-surface TTY / port-kick
/// bookkeeping: the bodies that stash a reported TTY name or port-scan kick
/// until a surface exists to bind it to, then apply the stash when a remote
/// terminal surface is tracked.
///
/// This lifts the decision/bookkeeping bodies of the legacy `Workspace` methods
/// `rememberPendingRemoteSurfaceTTY(_:requestedSurfaceId:)`,
/// `rememberPendingRemoteSurfacePortKick(reason:requestedSurfaceId:)`,
/// `applyPendingRemoteSurfaceTTYIfNeeded(to:)`,
/// `applyPendingRemoteSurfacePortKickIfNeeded(to:)`, and
/// `applyBootstrapRemoteTTY(_:)`. The workspace keeps thin forwarders so the
/// control-socket surface callers, the bootstrap publish adapter, and the
/// slice-4 `trackRemoteTerminalSurface` apply path still resolve.
///
/// The four pending stored fields stay on the workspace (they are also reset on
/// connect/disconnect outside this slice); the coordinator reads and writes
/// them, the per-surface TTY map, the active/focused surface reads, and the
/// port-scan forwards through ``RemoteSurfaceTTYHosting``.
///
/// ## Isolation design
///
/// `@MainActor`, matching the legacy isolation exactly: every lifted body was a
/// plain method on the `@MainActor` `Workspace` class, so every read, write, and
/// forward already ran on the main actor. The host reference is weak (the
/// workspace owns the coordinator), so there is no retain cycle.
@MainActor
public final class RemoteSurfaceTTYCoordinator<Host: RemoteSurfaceTTYHosting> {
    private weak var host: Host?

    /// Creates a coordinator. Call ``attach(host:)`` at the composition point
    /// before any pending-TTY orchestration runs so the live-workspace reads and
    /// pushes resolve.
    public init() {}

    /// Injects the live-workspace seam. Set before any orchestration runs.
    public func attach(host: Host) {
        self.host = host
    }

    /// Stashes a reported remote-surface TTY name (optionally bound to a
    /// requested surface) until a surface exists to apply it. Faithful lift of
    /// `Workspace.rememberPendingRemoteSurfaceTTY(_:requestedSurfaceId:)`.
    public func rememberPendingRemoteSurfaceTTY(_ ttyName: String, requestedSurfaceId: UUID?) {
        guard let host else { return }
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }
        host.hostPendingRemoteSurfaceTTYName = trimmedTTY
        host.hostPendingRemoteSurfaceTTYSurfaceId = requestedSurfaceId
    }

    /// Stashes a pending remote-surface port-kick reason (optionally bound to a
    /// requested surface). Faithful lift of
    /// `Workspace.rememberPendingRemoteSurfacePortKick(reason:requestedSurfaceId:)`.
    public func rememberPendingRemoteSurfacePortKick(
        reason: Host.PortKickReason,
        requestedSurfaceId: UUID?
    ) {
        guard let host else { return }
        host.hostPendingRemoteSurfacePortKickReason = reason
        host.hostPendingRemoteSurfacePortKickSurfaceId = requestedSurfaceId
    }

    /// Applies a pending TTY name to `panelId` if one is stashed and unbound or
    /// bound to this surface, then re-syncs and kicks a port scan. Faithful lift
    /// of `Workspace.applyPendingRemoteSurfaceTTYIfNeeded(to:)`.
    public func applyPendingRemoteSurfaceTTYIfNeeded(to panelId: UUID) {
        guard let host else { return }
        guard let ttyName = host.hostPendingRemoteSurfaceTTYName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return
        }
        if let requestedSurfaceId = host.hostPendingRemoteSurfaceTTYSurfaceId, requestedSurfaceId != panelId {
            return
        }
        host.hostSetSurfaceTTYName(ttyName, forPanel: panelId)
        host.hostPendingRemoteSurfaceTTYName = nil
        host.hostPendingRemoteSurfaceTTYSurfaceId = nil
        host.hostSyncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: panelId) {
            host.hostKickRemotePortScan(panelId: panelId, reason: host.hostDefaultCommandPortKickReason)
        }
    }

    /// Applies a pending port-kick to `panelId` if one is stashed, unbound or
    /// bound to this surface, and the surface has a TTY name. Faithful lift of
    /// `Workspace.applyPendingRemoteSurfacePortKickIfNeeded(to:)`.
    @discardableResult
    public func applyPendingRemoteSurfacePortKickIfNeeded(to panelId: UUID) -> Bool {
        guard let host else { return false }
        guard let reason = host.hostPendingRemoteSurfacePortKickReason else {
            return false
        }
        if let requestedSurfaceId = host.hostPendingRemoteSurfacePortKickSurfaceId,
           requestedSurfaceId != panelId {
            return false
        }
        guard let ttyName = host.hostSurfaceTTYName(forPanel: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return false
        }
        _ = ttyName
        host.hostPendingRemoteSurfacePortKickReason = nil
        host.hostPendingRemoteSurfacePortKickSurfaceId = nil
        host.hostKickRemotePortScan(panelId: panelId, reason: reason)
        return true
    }

    /// Binds a bootstrap-reported TTY name to the best candidate surface
    /// (focused live remote surface, else the sole live remote surface), or
    /// stashes it if none. Faithful lift of `Workspace.applyBootstrapRemoteTTY(_:)`.
    public func applyBootstrapRemoteTTY(_ ttyName: String) {
        guard let host else { return }
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }

        let candidateSurfaceId: UUID? = {
            if let focusedPanelId = host.hostFocusedPanelId,
               host.hostActiveRemoteTerminalSurfaceIds.contains(focusedPanelId) {
                return focusedPanelId
            }
            if host.hostActiveRemoteTerminalSurfaceIds.count == 1 {
                return host.hostActiveRemoteTerminalSurfaceIds.first
            }
            return nil
        }()

        guard let candidateSurfaceId else {
            rememberPendingRemoteSurfaceTTY(trimmedTTY, requestedSurfaceId: nil)
            return
        }

        host.hostSetSurfaceTTYName(trimmedTTY, forPanel: candidateSurfaceId)
        host.hostSyncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: candidateSurfaceId) {
            host.hostKickRemotePortScan(panelId: candidateSurfaceId, reason: host.hostDefaultCommandPortKickReason)
        }
    }
}

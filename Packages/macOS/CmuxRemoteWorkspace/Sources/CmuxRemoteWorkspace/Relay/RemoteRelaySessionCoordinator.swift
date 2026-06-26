public import Foundation
public import Observation

/// Per-workspace owner of the remote-relay alias maps and the per-panel
/// remote-PTY session-id store, plus the session-id derivations the snapshot and
/// attach-match paths consult.
///
/// This bundles two pieces of state that the legacy `Workspace` god class held
/// as private stored properties:
///
/// - the reverse-CLI-relay workspace/surface ID alias maps
///   (``RemoteRelayAliasRegistry``), with the guard-then-push bookkeeping that
///   pushes to the active remote session controller only on a real change, and
/// - the per-panel remote-PTY session-id map (`[panelId: sessionID]`), with the
///   set/get/remove/retain accessors the surface-creation, restore, prune, and
///   detach paths drive.
///
/// It also owns the two read-only derivations that combine that state with live
/// workspace reads: ``remotePTYSessionIDForSnapshot(panelId:)`` (the session id
/// to persist for a panel) and ``remotePTYSessionIDMatches(panelId:sessionID:)``
/// (whether an incoming attach session id matches the panel's expected id).
///
/// ## Isolation design
///
/// `@MainActor`, matching the legacy isolation exactly: every `Workspace`
/// method bundled here was a plain method on the `@MainActor` `Workspace`
/// class, so every alias mutation, session-id write, and the single controller
/// push already ran on the main actor. The coordinator reads the small slice of
/// live workspace state it needs (the workspace id, the remote configuration's
/// preserve flag, the active-remote-terminal surface set, the session-id
/// normalization, and the controller push) through ``RemoteRelaySessionHosting``.
/// The host reference is weak (the workspace owns the coordinator), so there is
/// no retain cycle.
@MainActor
@Observable
public final class RemoteRelaySessionCoordinator<Host: RemoteRelaySessionHosting> {
    /// The reverse-CLI-relay workspace/surface ID alias maps and their
    /// byte-faithful bookkeeping. Owned here; the controller push is forwarded
    /// through the host so it stays adjacent to the live session state.
    private var aliasRegistry = RemoteRelayAliasRegistry()

    /// Maps each tracked panel id to its remote-PTY session id (already
    /// normalized at every write site, exactly as the legacy store was).
    private var sessionIDsByPanelId: [UUID: String] = [:]

    @ObservationIgnored
    private weak var host: Host?

    /// Creates a relay-session coordinator. Call ``attach(host:)`` at the
    /// composition point before any bookkeeping runs so the live-workspace reads
    /// and the controller push resolve.
    public init() {}

    /// Injects the live-workspace seam. Set before any orchestration runs.
    public func attach(host: Host) {
        self.host = host
    }

    // MARK: - Remote-PTY session-id store

    /// The stored remote-PTY session id for `panelId`, or `nil` when none is
    /// recorded. Faithful read of `remotePTYSessionIDsByPanelId[panelId]`.
    public func remotePTYSessionID(forPanel panelId: UUID) -> String? {
        sessionIDsByPanelId[panelId]
    }

    /// Records `sessionID` for `panelId`. Faithful write of
    /// `remotePTYSessionIDsByPanelId[panelId] = sessionID`.
    public func setRemotePTYSessionID(_ sessionID: String, forPanel panelId: UUID) {
        sessionIDsByPanelId[panelId] = sessionID
    }

    /// Removes the stored session id for `panelId`. Faithful equivalent of
    /// `remotePTYSessionIDsByPanelId.removeValue(forKey: panelId)`.
    @discardableResult
    public func removeRemotePTYSessionID(forPanel panelId: UUID) -> String? {
        sessionIDsByPanelId.removeValue(forKey: panelId)
    }

    /// Drops every stored session id. Faithful equivalent of
    /// `remotePTYSessionIDsByPanelId.removeAll()`.
    public func removeAllRemotePTYSessionIDs() {
        sessionIDsByPanelId.removeAll()
    }

    /// Keeps only the session ids whose panel id is still valid. Faithful
    /// equivalent of
    /// `remotePTYSessionIDsByPanelId = remotePTYSessionIDsByPanelId.filter { validSurfaceIds.contains($0.key) }`.
    public func retainRemotePTYSessionIDs(validSurfaceIds: Set<UUID>) {
        sessionIDsByPanelId = sessionIDsByPanelId.filter { validSurfaceIds.contains($0.key) }
    }

    // MARK: - Relay alias bookkeeping

    /// Pushes the current alias maps to the active remote session controller via
    /// the host. Faithful lift of `Workspace.syncRemoteRelayIDAliasesToController()`.
    public func syncRemoteRelayIDAliasesToController() {
        host?.hostUpdateRemoteRelayIDAliases(
            workspaceAliases: aliasRegistry.workspaceAliases,
            surfaceAliases: aliasRegistry.surfaceAliases
        )
    }

    /// Drops every alias and pushes only when the maps actually changed.
    /// Faithful lift of `Workspace.clearRemoteRelayIDAliases()`.
    public func clearRemoteRelayIDAliases() {
        if aliasRegistry.clear() {
            syncRemoteRelayIDAliasesToController()
        }
    }

    /// Keeps only the surface aliases whose restored id is still valid, pushing
    /// only on a real change. Faithful lift of
    /// `Workspace.pruneRemoteRelaySurfaceAliases(validSurfaceIds:)`.
    public func pruneRemoteRelaySurfaceAliases(validSurfaceIds: Set<UUID>) {
        if aliasRegistry.pruneSurfaceAliases(validSurfaceIds: validSurfaceIds) {
            syncRemoteRelayIDAliasesToController()
        }
    }

    /// Removes every surface alias whose restored id equals `panelId`, pushing
    /// only on a real change. Faithful lift of
    /// `Workspace.removeRemoteRelaySurfaceAliases(targeting:)`.
    public func removeRemoteRelaySurfaceAliases(targeting panelId: UUID) {
        if aliasRegistry.removeSurfaceAliases(targeting: panelId) {
            syncRemoteRelayIDAliasesToController()
        }
    }

    /// Records the snapshot-to-restored mapping for a restored relay surface,
    /// pushing only on a real change. Faithful lift of
    /// `Workspace.registerRemoteRelayIDAliases(snapshotWorkspaceId:snapshotPanelId:restoredPanelId:)`.
    public func registerRemoteRelayIDAliases(
        snapshotWorkspaceId: UUID?,
        snapshotPanelId: UUID,
        restoredPanelId: UUID
    ) {
        guard let host else { return }
        let didMutate = aliasRegistry.register(
            snapshotWorkspaceId: snapshotWorkspaceId,
            snapshotPanelId: snapshotPanelId,
            restoredPanelId: restoredPanelId,
            localWorkspaceId: host.hostWorkspaceID
        )
        if didMutate {
            syncRemoteRelayIDAliasesToController()
        }
    }

    /// Parses a `ssh-<workspace>-<panel>` session id and records its mapping to
    /// the restored panel. Faithful lift of
    /// `Workspace.registerRemoteRelayIDAliases(remotePTYSessionID:restoredPanelId:)`.
    public func registerRemoteRelayIDAliases(remotePTYSessionID: String, restoredPanelId: UUID) {
        guard let parsed = SSHPTYSessionID(parsing: remotePTYSessionID) else { return }
        registerRemoteRelayIDAliases(
            snapshotWorkspaceId: parsed.workspaceId,
            snapshotPanelId: parsed.panelId,
            restoredPanelId: restoredPanelId
        )
    }

    /// Rewrites a relay command line using this workspace's current alias maps.
    /// Faithful lift of the instance `Workspace.rewriteRemoteRelayCommandLine(_:)`.
    public func rewriteRemoteRelayCommandLine(_ commandLine: Data) -> Data {
        aliasRegistry.rewrite(commandLine)
    }

    // MARK: - Session-id derivations

    /// The remote-PTY session id to persist in a snapshot for `panelId`, or
    /// `nil` when the panel carries no persistent session. Faithful lift of
    /// `Workspace.remotePTYSessionIDForSnapshot(panelId:)`.
    public func remotePTYSessionIDForSnapshot(panelId: UUID) -> String? {
        guard let host else { return nil }
        guard host.hostRemoteConfiguration?.preserveAfterTerminalExit == true else {
            return nil
        }
        if let storedSessionID = host.hostNormalizedRemotePTYSessionID(sessionIDsByPanelId[panelId]) {
            return storedSessionID
        }
        guard host.hostActiveRemoteTerminalSurfaceIds.contains(panelId) else {
            return nil
        }
        return SSHPTYSessionID(workspaceId: host.hostWorkspaceID, panelId: panelId).rawValue
    }

    /// True when `sessionID` matches the expected session id for `panelId` (the
    /// stored id, or the `ssh-<workspace>-<panel>` default), and the panel is an
    /// active remote terminal. Faithful lift of
    /// `Workspace.remotePTYSessionIDMatches(panelId:sessionID:)`.
    public func remotePTYSessionIDMatches(panelId: UUID, sessionID: String?) -> Bool {
        guard let host else { return false }
        guard host.hostActiveRemoteTerminalSurfaceIds.contains(panelId),
              let normalizedSessionID = host.hostNormalizedRemotePTYSessionID(sessionID) else {
            return false
        }
        let expectedSessionID = host.hostNormalizedRemotePTYSessionID(sessionIDsByPanelId[panelId])
            ?? SSHPTYSessionID(workspaceId: host.hostWorkspaceID, panelId: panelId).rawValue
        return normalizedSessionID == expectedSessionID
    }
}

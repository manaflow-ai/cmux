public import Foundation

/// Holds the reverse-CLI-relay workspace/surface ID alias maps for one
/// workspace and owns the byte-faithful bookkeeping that mutates them.
///
/// When a persistent-SSH-PTY session is restored under a new local
/// workspace/surface ID, these maps translate the snapshot (remote-minted) IDs
/// to the live local ones so relay commands addressed to the old IDs still hit
/// the right targets. The owning workspace holds one of these, keeps the push
/// to its session coordinator (`updateRemoteRelayIDAliases`), and forwards its
/// bookkeeping calls here. Each mutating method returns whether the maps
/// actually changed so the owner only pushes to the controller when there is a
/// real change, matching the legacy guard-then-sync structure exactly.
///
/// A value type, not a coordinator: it owns no live AppKit/session state and
/// does no I/O. The controller push stays with the owner because that touches
/// live session state. Rewriting is forwarded to
/// ``RemoteRelayCommandLineRewriter`` so the alias maps and the rewrite logic
/// live in one place.
public struct RemoteRelayAliasRegistry: Sendable {
    /// Maps snapshot (remote-minted) workspace IDs to their restored local IDs.
    public private(set) var workspaceAliases: [UUID: UUID]

    /// Maps snapshot (remote-minted) surface/panel IDs to their restored local IDs.
    public private(set) var surfaceAliases: [UUID: UUID]

    /// Creates a registry, optionally seeded with existing alias maps.
    public init(
        workspaceAliases: [UUID: UUID] = [:],
        surfaceAliases: [UUID: UUID] = [:]
    ) {
        self.workspaceAliases = workspaceAliases
        self.surfaceAliases = surfaceAliases
    }

    /// Drops every workspace and surface alias.
    ///
    /// Returns `true` when at least one alias was present (and was removed),
    /// `false` when both maps were already empty. Mirrors the legacy
    /// `clearRemoteRelayIDAliases` guard so the owner pushes to the controller
    /// only on a real change.
    @discardableResult
    public mutating func clear() -> Bool {
        guard !workspaceAliases.isEmpty || !surfaceAliases.isEmpty else { return false }
        workspaceAliases.removeAll()
        surfaceAliases.removeAll()
        return true
    }

    /// Keeps only the surface aliases whose restored (value) ID is still valid.
    ///
    /// Returns `true` when the surface map changed. Workspace aliases are left
    /// untouched, matching the legacy `pruneRemoteRelaySurfaceAliases`.
    @discardableResult
    public mutating func pruneSurfaceAliases(validSurfaceIds: Set<UUID>) -> Bool {
        let nextAliases = surfaceAliases.filter { validSurfaceIds.contains($0.value) }
        guard nextAliases != surfaceAliases else { return false }
        surfaceAliases = nextAliases
        return true
    }

    /// Removes every surface alias whose restored (value) ID equals `panelId`.
    ///
    /// Returns `true` when the surface map changed. Mirrors the legacy
    /// `removeRemoteRelaySurfaceAliases(targeting:)`.
    @discardableResult
    public mutating func removeSurfaceAliases(targeting panelId: UUID) -> Bool {
        let nextAliases = surfaceAliases.filter { $0.value != panelId }
        guard nextAliases != surfaceAliases else { return false }
        surfaceAliases = nextAliases
        return true
    }

    /// Records the snapshot-to-restored mapping for a restored relay surface.
    ///
    /// A workspace alias is recorded only when `snapshotWorkspaceId` is present,
    /// differs from `localWorkspaceId`, and is not already mapped to it; a
    /// surface alias only when `snapshotPanelId` differs from `restoredPanelId`
    /// and is not already mapped to it. Returns `true` when either map changed.
    /// Mirrors the legacy
    /// `registerRemoteRelayIDAliases(snapshotWorkspaceId:snapshotPanelId:restoredPanelId:)`,
    /// with the owner's own workspace ID passed in as `localWorkspaceId`.
    @discardableResult
    public mutating func register(
        snapshotWorkspaceId: UUID?,
        snapshotPanelId: UUID,
        restoredPanelId: UUID,
        localWorkspaceId: UUID
    ) -> Bool {
        var didMutate = false
        if let snapshotWorkspaceId, snapshotWorkspaceId != localWorkspaceId {
            if workspaceAliases[snapshotWorkspaceId] != localWorkspaceId {
                workspaceAliases[snapshotWorkspaceId] = localWorkspaceId
                didMutate = true
            }
        }
        if snapshotPanelId != restoredPanelId {
            if surfaceAliases[snapshotPanelId] != restoredPanelId {
                surfaceAliases[snapshotPanelId] = restoredPanelId
                didMutate = true
            }
        }
        return didMutate
    }

    /// Rewrites a relay command line using this registry's current alias maps.
    ///
    /// Forwards to ``RemoteRelayCommandLineRewriter/rewrite(_:workspaceAliases:surfaceAliases:)``.
    public func rewrite(_ commandLine: Data) -> Data {
        RemoteRelayCommandLineRewriter.rewrite(
            commandLine,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        )
    }
}

public import Foundation

/// Resolves each sidebar panel's working directory and the canonicalization
/// home directory from live workspace state read through a
/// ``SidebarMetadataHosting`` seam, lifted byte-for-byte from the legacy
/// `Workspace` DirectoryUpdates section (`sidebarResolvedDirectory(for:)`,
/// `sidebarResolvedPanelDirectories(orderedPanelIds:)`, and
/// `sidebarHomeDirectoryForCanonicalization(resolvedPanelDirectories:)`).
///
/// This is the live-state half of the sidebar directory projection: it turns
/// per-panel reads (the panel's reported directory, its terminal-requested
/// directory, the focused panel, the workspace's current directory, and whether
/// the workspace is remote) into the resolved `[UUID: String]` directory map and
/// canonicalization home that
/// ``WorkspaceSidebarMetadataModel/directoriesInDisplayOrder(orderedPanelIds:resolvedPanelDirectories:homeDirectoryForCanonicalization:fallbackDirectory:includeFallback:)``
/// and the branch+directory projection consume. The pure ordering/dedup step
/// remains on the metadata model; the stateless directory math remains on
/// ``SidebarBranchOrdering``.
///
/// Stateless by design beyond its host reference: a throwaway value mirroring
/// ``SidebarBranchOrdering``, so the resolution rules have one owner instead of
/// being inlined in the god file.
@MainActor
public struct SidebarDirectoryResolver {
    private let host: any SidebarMetadataHosting

    /// Creates a resolver reading live workspace state through `host`.
    /// - Parameter host: The read-only seam supplying per-panel directories and
    ///   the workspace-level canonicalization inputs.
    public init(host: any SidebarMetadataHosting) {
        self.host = host
    }

    /// The home directory used to tilde-expand displayed directories when
    /// deduplicating sidebar rows (legacy
    /// `Workspace.sidebarHomeDirectoryForCanonicalization(resolvedPanelDirectories:)`).
    ///
    /// For a remote workspace the home is inferred from the observed panel
    /// directories (tilde-form vs absolute-form agreement); otherwise it is the
    /// current user's home directory.
    /// - Parameter resolvedPanelDirectories: The resolved directory per panel,
    ///   from which the remote home is inferred.
    /// - Returns: The canonicalization home directory, or `nil` when none can be
    ///   inferred for a remote workspace.
    public func homeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        if host.sidebarIsRemoteWorkspace {
            return SidebarBranchOrdering().inferredRemoteHomeDirectory(
                from: Array(resolvedPanelDirectories.values),
                fallbackDirectory: SidebarBranchOrdering().normalizedDirectory(host.sidebarCurrentDirectory)
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Resolves a single panel's displayed directory from live state (legacy
    /// `Workspace.sidebarResolvedDirectory(for:)`).
    ///
    /// Prefers the panel's reported directory, then its terminal-requested
    /// directory, and finally (only for the focused panel) the workspace's
    /// current directory.
    /// - Parameter panelId: The panel whose directory is resolved.
    /// - Returns: The normalized resolved directory, or `nil` when none applies.
    public func resolvedDirectory(for panelId: UUID) -> String? {
        if let directory = SidebarBranchOrdering().normalizedDirectory(host.sidebarPanelDirectory(for: panelId)) {
            return directory
        }
        if let requestedDirectory = SidebarBranchOrdering().normalizedDirectory(
            host.sidebarPanelRequestedWorkingDirectory(for: panelId)
        ) {
            return requestedDirectory
        }
        guard panelId == host.sidebarFocusedPanelId else { return nil }
        return SidebarBranchOrdering().normalizedDirectory(host.sidebarCurrentDirectory)
    }

    /// Resolves the displayed directory for each panel in spatial order, keyed
    /// by panel id (legacy
    /// `Workspace.sidebarResolvedPanelDirectories(orderedPanelIds:)`).
    /// - Parameter orderedPanelIds: Panel ids in spatial display order.
    /// - Returns: The resolved directory per panel, omitting panels with none.
    public func resolvedPanelDirectories(orderedPanelIds: [UUID]) -> [UUID: String] {
        var resolved: [UUID: String] = [:]
        for panelId in orderedPanelIds {
            if let directory = resolvedDirectory(for: panelId) {
                resolved[panelId] = directory
            }
        }
        return resolved
    }
}

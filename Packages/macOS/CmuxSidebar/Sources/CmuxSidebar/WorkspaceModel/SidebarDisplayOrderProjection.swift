public import Foundation

/// Projects the sidebar's ordered display lists (directories, the Finder-reveal
/// directory, git branches, branch+directory rows, pull requests, status
/// entries, metadata blocks) from the spatial panel order and per-panel live
/// state read through a ``SidebarMetadataHosting`` seam, combining the stateless
/// directory resolution (``SidebarDirectoryResolver``) with the per-panel
/// metadata the ``WorkspaceSidebarMetadataModel`` owns.
///
/// Lifted byte-for-byte from the legacy `Workspace` sidebar display-ordering
/// forwarders (`sidebarDirectoriesInDisplayOrder`, `sidebarFinderDirectory`,
/// `sidebarGitBranchesInDisplayOrder`,
/// `sidebarBranchDirectoryEntriesInDisplayOrder`,
/// `sidebarPullRequestsInDisplayOrder`, `sidebarStatusEntriesInDisplayOrder`,
/// `sidebarMetadataBlocksInDisplayOrder`). The irreducible live-state reads (the
/// bonsplit spatial order behind ``SidebarMetadataHosting/sidebarSpatialPanelOrder``,
/// remote-surface classification behind
/// ``SidebarMetadataHosting/sidebarIsRemoteDisplaySurface(_:)``, and the
/// agent-visibility status filtering behind
/// ``SidebarMetadataHosting/sidebarVisibleStatusEntriesForDisplay``) stay in the
/// `Workspace` shim; this type owns the combination/ordering glue so it has one
/// owner in the sidebar domain instead of being inlined in the god file.
///
/// Stateless by design beyond its references (the seam host and the metadata
/// model): a throwaway value constructed per use, mirroring
/// ``SidebarDirectoryResolver``.
@MainActor
public struct SidebarDisplayOrderProjection {
    private let host: any SidebarMetadataHosting
    private let metadata: WorkspaceSidebarMetadataModel
    private let directoryResolver: SidebarDirectoryResolver

    /// Creates a projection reading live workspace state through `host` and the
    /// per-panel git/PR/directory metadata from `metadata`.
    /// - Parameters:
    ///   - host: The read-only seam supplying spatial order, per-panel
    ///     directories, remote classification, and visible status entries.
    ///   - metadata: The per-panel sidebar metadata model owning the git
    ///     branches, pull requests, status entries, and metadata blocks.
    public init(host: any SidebarMetadataHosting, metadata: WorkspaceSidebarMetadataModel) {
        self.host = host
        self.metadata = metadata
        self.directoryResolver = SidebarDirectoryResolver(host: host)
    }

    /// Unique displayed directories in spatial panel order (legacy
    /// `Workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds:includeFallback:)`).
    /// - Parameters:
    ///   - orderedPanelIds: Panel ids in spatial display order.
    ///   - includeFallback: Whether to fall back to the normalized current
    ///     directory when no panel contributes a directory.
    /// - Returns: The unique directories in display order.
    public func directoriesInDisplayOrder(
        orderedPanelIds: [UUID],
        includeFallback: Bool = true
    ) -> [String] {
        let resolvedDirectories = directoryResolver.resolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        return metadata.directoriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds,
            resolvedPanelDirectories: resolvedDirectories,
            homeDirectoryForCanonicalization: directoryResolver.homeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            ),
            fallbackDirectory: SidebarBranchOrdering().normalizedDirectory(host.sidebarCurrentDirectory),
            includeFallback: includeFallback
        )
    }

    /// Unique displayed directories in spatial panel order, over the host's
    /// current spatial panel order (legacy
    /// `Workspace.sidebarDirectoriesInDisplayOrder()`).
    /// - Returns: The unique directories in display order.
    public func directoriesInDisplayOrder() -> [String] {
        directoriesInDisplayOrder(orderedPanelIds: host.sidebarSpatialPanelOrder)
    }

    /// The directory to reveal in Finder for a local workspace: the first
    /// displayed directory among the non-remote panels (legacy
    /// `Workspace.sidebarFinderDirectory()`).
    /// - Returns: The Finder-reveal directory, or `nil` for a remote workspace
    ///   or when no local directory is available.
    public func finderDirectory() -> String? {
        guard !host.sidebarIsRemoteWorkspace else { return nil }
        let panelIds = host.sidebarSpatialPanelOrder
        let localPanelIds = panelIds.filter { !host.sidebarIsRemoteDisplaySurface($0) }
        return directoriesInDisplayOrder(
            orderedPanelIds: localPanelIds,
            includeFallback: panelIds.isEmpty || localPanelIds.count == panelIds.count
        ).first
    }

    /// Unique git branches in spatial panel order (legacy
    /// `Workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds:)`).
    /// - Parameter orderedPanelIds: Panel ids in spatial display order.
    /// - Returns: The unique branch states in display order.
    public func gitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        metadata.gitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds)
    }

    /// Unique git branches over the host's current spatial panel order (legacy
    /// `Workspace.sidebarGitBranchesInDisplayOrder()`).
    /// - Returns: The unique branch states in display order.
    public func gitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        gitBranchesInDisplayOrder(orderedPanelIds: host.sidebarSpatialPanelOrder)
    }

    /// Unique branch+directory rows in spatial panel order (legacy
    /// `Workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds:)`).
    /// - Parameter orderedPanelIds: Panel ids in spatial display order.
    /// - Returns: The unique branch+directory rows in display order.
    public func branchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        let resolvedDirectories = directoryResolver.resolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        return metadata.branchDirectoryEntriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds,
            resolvedPanelDirectories: resolvedDirectories,
            defaultDirectory: SidebarBranchOrdering().normalizedDirectory(host.sidebarCurrentDirectory),
            homeDirectoryForCanonicalization: directoryResolver.homeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            )
        )
    }

    /// Unique branch+directory rows over the host's current spatial panel order
    /// (legacy `Workspace.sidebarBranchDirectoryEntriesInDisplayOrder()`).
    /// - Returns: The unique branch+directory rows in display order.
    public func branchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        branchDirectoryEntriesInDisplayOrder(orderedPanelIds: host.sidebarSpatialPanelOrder)
    }

    /// Unique pull requests in spatial panel order (legacy
    /// `Workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds:)`).
    /// - Parameter orderedPanelIds: Panel ids in spatial display order.
    /// - Returns: The unique pull-request states in display order.
    public func pullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        metadata.pullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds)
    }

    /// Unique pull requests over the host's current spatial panel order (legacy
    /// `Workspace.sidebarPullRequestsInDisplayOrder()`).
    /// - Returns: The unique pull-request states in display order.
    public func pullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        pullRequestsInDisplayOrder(orderedPanelIds: host.sidebarSpatialPanelOrder)
    }

    /// The visible status entries sorted for sidebar display (legacy
    /// `Workspace.sidebarStatusEntriesInDisplayOrder()`).
    /// - Returns: The visible status entries in stable display order.
    public func statusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        metadata.statusEntriesInDisplayOrder(host.sidebarVisibleStatusEntriesForDisplay)
    }

    /// The metadata blocks sorted for sidebar display (legacy
    /// `Workspace.sidebarMetadataBlocksInDisplayOrder()`).
    /// - Returns: The metadata blocks in stable display order.
    public func metadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        metadata.metadataBlocksInDisplayOrder()
    }
}

public import Foundation

/// Sidebar display-order projections and git/pull-request metadata mutators,
/// lifted byte-for-byte from the legacy `Workspace` Directory-Updates section.
///
/// These derive the sidebar's branch / pull-request / directory rows from the
/// per-panel state this model already owns (`panelGitBranches`,
/// `panelPullRequests`, `gitBranch`, `pullRequest`), plus the spatial panel
/// order and the resolved per-panel working directories. The ordering itself
/// is computed by the stateless ``SidebarBranchOrdering``.
///
/// Inputs that depend on app-target state the package must not import (the
/// bonsplit spatial order, `TerminalPanel.requestedWorkingDirectory`, remote
/// surface classification, the focused panel) are resolved by the app target
/// and passed in as plain value parameters: `orderedPanelIds`, the resolved
/// `[UUID: String]` directory map, the canonicalization home directory, the
/// fallback directory, and `focusedPanelId`. This keeps the projection logic
/// in the owning domain while leaving the irreducible live-state resolution in
/// the `Workspace` shim, which forwards to these methods.
extension WorkspaceSidebarMetadataModel {
    // MARK: - Git / pull-request mutators

    /// Records a panel's git branch, clearing a stale pull request when the
    /// branch changes, and mirrors the focused panel's state up to the
    /// workspace-level `gitBranch`/`pullRequest` (legacy
    /// `Workspace.updatePanelGitBranch(panelId:branch:isDirty:)`).
    /// - Parameters:
    ///   - panelId: The panel whose branch state is being recorded.
    ///   - branch: The branch name reported for the panel.
    ///   - isDirty: Whether the panel's working tree is dirty.
    ///   - focusedPanelId: The workspace's currently focused panel id, used to
    ///     decide whether to mirror state up to the workspace level.
    public func updatePanelGitBranch(
        panelId: UUID,
        branch: String,
        isDirty: Bool,
        focusedPanelId: UUID?
    ) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        let branchChanged = existing?.branch != nil && existing?.branch != branch
        if existing?.branch != branch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
        }
        if branchChanged {
            if panelPullRequests[panelId] != nil {
                panelPullRequests.removeValue(forKey: panelId)
            }
            if panelId == focusedPanelId, pullRequest != nil {
                pullRequest = nil
            }
        }
        if panelId == focusedPanelId, gitBranch != state {
            gitBranch = state
        }
    }

    /// Clears a panel's git branch and pull request, also clearing the
    /// workspace-level state when the panel is focused (legacy
    /// `Workspace.clearPanelGitBranch(panelId:)`).
    /// - Parameters:
    ///   - panelId: The panel whose branch/pull-request state is cleared.
    ///   - focusedPanelId: The workspace's currently focused panel id.
    public func clearPanelGitBranch(panelId: UUID, focusedPanelId: UUID?) {
        if panelGitBranches[panelId] != nil {
            panelGitBranches.removeValue(forKey: panelId)
        }
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId {
            if gitBranch != nil {
                gitBranch = nil
            }
            if pullRequest != nil {
                pullRequest = nil
            }
        }
    }

    /// Records a panel's pull request, resolving its branch from the explicit
    /// argument, the panel's current branch, or the prior pull request, and
    /// mirrors the focused panel's pull request up to the workspace level
    /// (legacy `Workspace.updatePanelPullRequest(...)`).
    /// - Parameters:
    ///   - panelId: The panel whose pull request is recorded.
    ///   - number: The pull-request number.
    ///   - label: The pull-request label.
    ///   - url: The pull-request review URL.
    ///   - status: The pull-request status.
    ///   - branch: The associated branch, if explicitly known.
    ///   - isStale: Whether the pull-request data is stale.
    ///   - focusedPanelId: The workspace's currently focused panel id.
    public func updatePanelPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        isStale: Bool = false,
        focusedPanelId: UUID?
    ) {
        let existing = panelPullRequests[panelId]
        let normalizedBranch = branch?.normalizedSidebarBranchName
        let currentPanelBranch = panelGitBranches[panelId]?.branch.normalizedSidebarBranchName
        let resolvedBranch: String? = {
            if let normalizedBranch {
                return normalizedBranch
            }
            if let currentPanelBranch {
                return currentPanelBranch
            }
            guard let existing,
                  existing.number == number,
                  existing.label == label,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.branch
        }()
        let state = SidebarPullRequestState(
            number: number,
            label: label,
            url: url,
            status: status,
            branch: resolvedBranch,
            isStale: isStale
        )
        if existing != state {
            panelPullRequests[panelId] = state
        }
        if panelId == focusedPanelId, pullRequest != state {
            pullRequest = state
        }
    }

    /// Clears a panel's pull request, also clearing the workspace-level pull
    /// request when the panel is focused (legacy
    /// `Workspace.clearPanelPullRequest(panelId:)`).
    /// - Parameters:
    ///   - panelId: The panel whose pull request is cleared.
    ///   - focusedPanelId: The workspace's currently focused panel id.
    public func clearPanelPullRequest(panelId: UUID, focusedPanelId: UUID?) {
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId, pullRequest != nil {
            pullRequest = nil
        }
    }

    /// Clears all pull-request metadata, panel-level and workspace-level
    /// (legacy `Workspace.clearSidebarPullRequestMetadata()`).
    public func clearPullRequestMetadata() {
        if !panelPullRequests.isEmpty {
            panelPullRequests.removeAll()
        }
        if pullRequest != nil {
            pullRequest = nil
        }
    }

    /// Clears all git-branch metadata (and the pull-request metadata, since a
    /// pull request without a branch is meaningless), panel-level and
    /// workspace-level (legacy `Workspace.clearSidebarGitMetadata()`).
    public func clearGitMetadata() {
        if !panelGitBranches.isEmpty {
            panelGitBranches.removeAll()
        }
        clearPullRequestMetadata()
        if gitBranch != nil {
            gitBranch = nil
        }
    }

    // MARK: - Display-order projections

    /// Unique displayed directories in spatial panel order, deduplicated by
    /// their canonical (tilde-expanded, standardized) key (legacy
    /// `Workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds:includeFallback:)`).
    ///
    /// The caller resolves each panel's directory (reading
    /// `TerminalPanel.requestedWorkingDirectory` and remote state the package
    /// cannot import) into `resolvedPanelDirectories`, and computes the
    /// canonicalization home directory; this method performs only the
    /// order-preserving deduplication.
    /// - Parameters:
    ///   - orderedPanelIds: Panel ids in spatial display order.
    ///   - resolvedPanelDirectories: The resolved directory per panel.
    ///   - homeDirectoryForCanonicalization: The home directory used for tilde
    ///     expansion when computing canonical keys.
    ///   - fallbackDirectory: The normalized current directory, returned alone
    ///     when no panel contributes a directory and `includeFallback` is true.
    ///   - includeFallback: Whether to fall back to `fallbackDirectory` when
    ///     the ordered result is empty.
    /// - Returns: The unique directories in display order.
    public func directoriesInDisplayOrder(
        orderedPanelIds: [UUID],
        resolvedPanelDirectories: [UUID: String],
        homeDirectoryForCanonicalization: String?,
        fallbackDirectory: String?,
        includeFallback: Bool = true
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        for panelId in orderedPanelIds {
            guard let directory = resolvedPanelDirectories[panelId],
                  let key = SidebarBranchOrdering().canonicalDirectoryKey(
                      directory,
                      homeDirectoryForTildeExpansion: homeDirectoryForCanonicalization
                  ) else { continue }
            if seen.insert(key).inserted {
                ordered.append(directory)
            }
        }

        if includeFallback, ordered.isEmpty, let fallbackDirectory {
            return [fallbackDirectory]
        }

        return ordered
    }

    /// Unique git branches in spatial panel order, dirty if any contributing
    /// panel is dirty (legacy
    /// `Workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds:)`).
    /// - Parameter orderedPanelIds: Panel ids in spatial display order.
    /// - Returns: The unique branch states in display order.
    public func gitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering()
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    /// Unique branch+directory rows in spatial panel order, one row per
    /// canonical directory (legacy
    /// `Workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds:)`).
    /// - Parameters:
    ///   - orderedPanelIds: Panel ids in spatial display order.
    ///   - resolvedPanelDirectories: The resolved directory per panel.
    ///   - defaultDirectory: The normalized current directory used as the
    ///     fallback row's directory.
    ///   - homeDirectoryForCanonicalization: The home directory used for tilde
    ///     expansion when computing canonical keys.
    /// - Returns: The unique branch+directory rows in display order.
    public func branchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID],
        resolvedPanelDirectories: [UUID: String],
        defaultDirectory: String?,
        homeDirectoryForCanonicalization: String?
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        SidebarBranchOrdering().orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: panelGitBranches,
            panelDirectories: resolvedPanelDirectories,
            defaultDirectory: defaultDirectory,
            homeDirectoryForTildeExpansion: homeDirectoryForCanonicalization,
            fallbackBranch: gitBranch
        )
    }

    /// Unique pull requests in spatial panel order, dropping any panel pull
    /// request whose branch no longer matches the panel's current branch
    /// (legacy `Workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds:)`).
    /// - Parameter orderedPanelIds: Panel ids in spatial display order.
    /// - Returns: The unique pull-request states in display order.
    public func pullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        let validPanelPullRequests = panelPullRequests.filter { panelId, state in
            guard let pullRequestBranch = state.branch?.normalizedSidebarBranchName else {
                return true
            }
            return panelGitBranches[panelId]?.branch.normalizedSidebarBranchName == pullRequestBranch
        }
        return SidebarBranchOrdering().orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            panelPullRequests: validPanelPullRequests,
            fallbackPullRequest: nil
        )
    }
}

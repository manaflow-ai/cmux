import Foundation

/// Pure derivation of a ``SidebarWorkspaceSnapshotBuilder/Snapshot`` from the
/// value arrays the app-side witness gathers off live `Workspace`/`Tab` state.
///
/// `TabItemView` reads the workspace's ordered branch/directory/pull-request
/// projections and resolved tab content, hands them here as plain value types,
/// and this extension folds them into the row's single `Equatable` snapshot:
/// the branch `*`/dirty formatting, the `ViewThatFits` directory-candidate
/// gradient walk, the pull-request display-id construction, and the
/// custom-description visibility check all live here, operating purely on value
/// inputs with no model access. The methods are `static` because the builder is
/// the namespace that owns ``SidebarWorkspaceSnapshotBuilder/Snapshot`` and the
/// transform has no state to inject (the sanctioned "static factory on the value
/// type it produces" shape).
extension SidebarWorkspaceSnapshotBuilder {
    /// The legacy auto-generated VM description that is suppressed for `vm:`
    /// workspaces so it never renders as a user-authored custom description.
    private static let legacyVMWebSocketDescription = "VM WebSocket PTY"

    /// Folds the gathered value arrays and resolved tab content into the row's
    /// single presentation snapshot.
    ///
    /// - Parameters:
    ///   - presentationKey: The layout-affecting flags, compared to detect
    ///     re-layout needs.
    ///   - branches: The ordered git-branch states for the inline (non-vertical)
    ///     branch summary. Empty when the inline branch summary is not shown.
    ///   - directoryEntries: The ordered branch+directory entries for the
    ///     vertical layout. Empty when the vertical layout is not shown.
    ///   - directories: The ordered panel directories for the inline directory
    ///     candidates. Empty when the inline directory line is not shown.
    ///   - pullRequests: The ordered pull-request states. Empty when PR badges
    ///     are not shown.
    ///   - settings: The resolved sidebar tab-item settings.
    ///   - flags: The resolved per-render tab content.
    ///   - finderDirectoryPath: The Finder-revealable directory path, or `nil`.
    /// - Returns: The fully-resolved sidebar row snapshot.
    public static func snapshot(
        presentationKey: PresentationKey,
        branches: [SidebarGitBranchState],
        directoryEntries: [SidebarBranchOrdering.BranchDirectoryEntry],
        directories: [String],
        pullRequests: [SidebarPullRequestState],
        settings: SidebarTabItemSettingsSnapshot,
        flags: RowInputs,
        finderDirectoryPath: String?
    ) -> Snapshot {
        let compactGitBranchSummaryText = gitBranchSummaryText(branches: branches)
        let compactDirectoryCandidates = compactDirectoryCandidatesList(
            directories: directories,
            usesViewportAwarePath: settings.usesLastSegmentPath
        )
        let compactBranchDirectoryCandidates = compactBranchDirectoryCandidatesList(
            gitSummary: compactGitBranchSummaryText,
            directoryCandidates: compactDirectoryCandidates
        )
        let branchDirectoryLines = verticalBranchDirectoryLines(
            entries: directoryEntries,
            showsGitBranch: settings.showsGitBranch,
            usesViewportAwarePath: settings.usesLastSegmentPath
        )
        let branchLinesContainBranch = settings.showsGitBranch
            && branchDirectoryLines.contains { $0.branch != nil }
        let pullRequestRows = pullRequestDisplays(pullRequests: pullRequests)

        return Snapshot(
            presentationKey: presentationKey,
            title: flags.title,
            customDescription: settings.showsWorkspaceDescription
                ? visibleCustomDescription(title: flags.title, customDescription: flags.customDescription)
                : nil,
            isPinned: flags.isPinned,
            customColorHex: flags.customColorHex,
            remoteWorkspaceSidebarText: flags.remoteWorkspaceSidebarText,
            remoteConnectionStatusText: flags.remoteConnectionStatusText,
            remoteStateHelpText: flags.remoteStateHelpText,
            showsRemoteReconnectAffordance: flags.showsRemoteReconnectAffordance,
            copyableSidebarSSHError: flags.copyableSidebarSSHError,
            latestConversationMessage: flags.latestConversationMessage,
            metadataEntries: flags.metadataEntries,
            metadataBlocks: flags.metadataBlocks,
            latestLog: flags.latestLog,
            progress: flags.progress,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: flags.listeningPorts,
            finderDirectoryPath: finderDirectoryPath,
            mediaActivity: flags.mediaActivity
        )
    }

    /// The custom workspace description to display, suppressing the legacy
    /// auto-generated VM WebSocket description for `vm:` workspaces.
    private static func visibleCustomDescription(title: String, customDescription: String?) -> String? {
        guard let description = customDescription else { return nil }
        if title.hasPrefix("vm:"),
           description.trimmingCharacters(in: .whitespacesAndNewlines) == legacyVMWebSocketDescription {
            return nil
        }
        return description
    }

    // Builds the joined "branch · directory" candidates list for inline mode.
    // Each entry pairs the (fixed) git summary with one entry from the
    // directory candidates list, so ViewThatFits can choose how aggressively to
    // shorten the directory portion as the row width changes.
    private static func compactBranchDirectoryCandidatesList(
        gitSummary: String?,
        directoryCandidates: [String]
    ) -> [String] {
        if directoryCandidates.isEmpty {
            return gitSummary.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        }
        guard let gitSummary, !gitSummary.isEmpty else { return directoryCandidates }
        return directoryCandidates.map { "\(gitSummary) · \($0)" }
    }

    private static func gitBranchSummaryText(branches: [SidebarGitBranchState]) -> String? {
        let lines = gitBranchSummaryLines(branches: branches)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private static func gitBranchSummaryLines(branches: [SidebarGitBranchState]) -> [String] {
        branches.map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
    }

    private static func verticalBranchDirectoryLines(
        entries: [SidebarBranchOrdering.BranchDirectoryEntry],
        showsGitBranch: Bool,
        usesViewportAwarePath: Bool
    ) -> [VerticalBranchDirectoryLine] {
        let pathFormatter = SidebarPathFormatter()
        let home = pathFormatter.homeDirectoryPath
        return entries.compactMap { entry in
            let branchText: String? = {
                guard showsGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()

            let directoryCandidates: [String] = {
                guard let directory = entry.directory else { return [] }
                if usesViewportAwarePath {
                    return pathFormatter.pathCandidates(directory, homeDirectoryPath: home)
                }
                let shortened = pathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                return shortened.isEmpty ? [] : [shortened]
            }()

            if branchText == nil && directoryCandidates.isEmpty {
                return nil
            }
            return VerticalBranchDirectoryLine(
                branch: branchText,
                directoryCandidates: directoryCandidates
            )
        }
    }

    // Candidates for the inline-mode directory line, longest → shortest. When
    // viewport-aware truncation is off, returns a single element with each
    // panel directory shortened via `~/`. When on, walks per-path candidate
    // indices, bumping the rightmost path that can still shrink at each step.
    // Each emitted candidate differs from the previous by exactly one path
    // collapsing one level, so ViewThatFits sees a strictly monotone gradient
    // (`full|full`, `full|mid`, `full|leaf`, `mid|leaf`, `leaf|leaf`) — later
    // panels shrink before earlier ones, preserving the leading workspace dir
    // as long as the row width allows.
    private static func compactDirectoryCandidatesList(
        directories: [String],
        usesViewportAwarePath: Bool
    ) -> [String] {
        let pathFormatter = SidebarPathFormatter()
        let home = pathFormatter.homeDirectoryPath
        guard !directories.isEmpty else { return [] }

        if !usesViewportAwarePath {
            let joined = directories
                .map { pathFormatter.shortenedPath($0, homeDirectoryPath: home) }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return joined.isEmpty ? [] : [joined]
        }

        let perDirectoryCandidates: [[String]] = directories
            .map { pathFormatter.pathCandidates($0, homeDirectoryPath: home) }
            .filter { !$0.isEmpty }
        guard !perDirectoryCandidates.isEmpty else { return [] }

        var indices = Array(repeating: 0, count: perDirectoryCandidates.count)
        var result: [String] = []
        while true {
            let pieces = zip(indices, perDirectoryCandidates).map { idx, candidates in
                candidates[idx]
            }
            let joined = pieces.joined(separator: " | ")
            if !joined.isEmpty, result.last != joined {
                result.append(joined)
            }
            guard let bumpIdx = indices.indices.last(where: { indices[$0] < perDirectoryCandidates[$0].count - 1 }) else {
                break
            }
            indices[bumpIdx] += 1
        }
        return result
    }

    private static func pullRequestDisplays(pullRequests: [SidebarPullRequestState]) -> [PullRequestDisplay] {
        pullRequests.map { pullRequest in
            PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                isStale: pullRequest.isStale
            )
        }
    }
}

import AppKit
import CmuxSidebar
import CmuxWorkspaces
import Foundation

/// Builds the immutable value passed across the workspace sidebar's
/// `LazyVStack` boundary.
///
/// The factory is created and consumed by the parent row builder; it is never
/// stored by a SwiftUI row. This keeps live `Workspace` state on the owning side
/// of the lazy-list boundary while preserving the existing presentation rules.
@MainActor
struct SidebarWorkspaceSnapshotFactory {
    private static let legacyVMWebSocketDescription = "VM WebSocket PTY"

    let workspace: Workspace
    let workspaceNumber: Int
    let settings: SidebarTabItemSettingsSnapshot
    let showsAgentActivity: Bool

    func makeSnapshot() -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let detailVisibility = settings.visibleAuxiliaryDetails
        let orderedPanelIds: [UUID]? =
            (detailVisibility.showsBranchDirectory || detailVisibility.showsPullRequests)
                ? workspace.sidebarOrderedPanelIds()
                : nil
        let compactGitBranchSummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  settings.branchDirectory.branchLayout == .inline,
                  settings.showsGitBranch,
                  let orderedPanelIds else {
                return nil
            }
            return gitBranchSummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactDirectoryCandidates: [String] = {
            guard detailVisibility.showsBranchDirectory,
                  settings.branchDirectory.branchLayout == .inline,
                  let orderedPanelIds else {
                return []
            }
            return compactDirectoryCandidatesList(orderedPanelIds: orderedPanelIds)
        }()
        let compactBranchDirectoryCandidates = compactBranchDirectoryCandidatesList(
            gitSummary: compactGitBranchSummaryText,
            directoryCandidates: compactDirectoryCandidates
        )
        let branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] = {
            guard detailVisibility.showsBranchDirectory,
                  settings.branchDirectory.branchLayout == .vertical,
                  let orderedPanelIds else {
                return []
            }
            return verticalBranchDirectoryLines(orderedPanelIds: orderedPanelIds)
        }()
        let pullRequestRows: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] = {
            guard detailVisibility.showsPullRequests, let orderedPanelIds else { return [] }
            return pullRequestDisplays(orderedPanelIds: orderedPanelIds)
        }()
        let todoControlsEnabled = WorkspaceTodoFeature.isEnabled
        let workspaceStatusVisible = todoControlsEnabled && !workspace.todoState.statusHidden
        let inferredTaskStatus = workspaceStatusVisible ? workspace.inferredTaskStatus : nil
        let taskStatusResolution: WorkspaceTaskStatusOverride.Resolution? = inferredTaskStatus.map { inferred in
            WorkspaceTaskStatusOverride.effectiveStatus(
                override: workspace.todoState.statusOverride,
                inferred: inferred
            )
        }
        let hasManualTaskStatus = workspaceStatusVisible
            && workspace.todoState.statusOverride != nil
            && taskStatusResolution?.shouldClearOverride == false
        let todoStatusMenuModel = inferredTaskStatus.map { inferred in
            SidebarWorkspaceCompactStatusMenuModel.resolve(
                inferred: inferred,
                override: workspace.todoState.statusOverride
            )
        }
        let checklistProgress = workspace.checklistProgressSummary

        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: presentationKey,
            title: workspace.title,
            customDescription: settings.showsWorkspaceDescription ? visibleCustomDescription : nil,
            isPinned: workspace.isPinned,
            customColorHex: workspace.customColor,
            sessionCard: makeSessionCardSnapshot(),
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            showsRemoteReconnectAffordance: !workspace.isManagedCloudVMWorkspace
                && (workspace.remoteConnectionState == .suspended
                    || workspace.remoteConnectionState == .disconnected),
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestConversationMessage: workspace.latestConversationMessage,
            metadataEntries: detailVisibility.showsMetadata
                ? workspace.sidebarStatusEntriesInDisplayOrder()
                : [],
            metadataBlocks: detailVisibility.showsMetadata
                ? workspace.sidebarMetadataBlocksInDisplayOrder()
                : [],
            latestLog: detailVisibility.showsLog ? workspace.logEntries.last : nil,
            progress: detailVisibility.showsProgress ? workspace.progress : nil,
            activeCodingAgentCount: SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
                showsAgentActivity: showsAgentActivity,
                statesByPanelId: workspace.agentLifecycleStatesByPanelId
            ),
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: settings.showsGitBranch
                && branchDirectoryLines.contains { $0.branch != nil },
            pullRequestRows: pullRequestRows,
            listeningPorts: detailVisibility.showsPorts ? workspace.listeningPorts : [],
            finderDirectoryPath: WorkspaceFinderDirectoryResolver.path(for: workspace),
            mediaActivity: workspace.browserMediaActivity,
            taskStatus: taskStatusResolution?.effective,
            todoStatusMenuModel: todoStatusMenuModel,
            hasManualTaskStatus: hasManualTaskStatus,
            checklistItems: workspace.todoState.checklist,
            checklistCompletedCount: checklistProgress.completedCount,
            checklistTotalCount: checklistProgress.totalCount,
            checklistFirstUncheckedText: checklistProgress.firstUncheckedText
        )
    }

    private func makeSessionCardSnapshot() -> SessionCardSnapshot {
        let host: SessionCardSnapshot.Host = workspace.isRemoteWorkspace
            || workspace.hasActiveRemoteTerminalSessions ? .devbox : .laptop
        let worktreeNumber = indexedWorktreeNumber()
        let status = SessionCardSnapshot.Status.resolve(workspace: workspace)
        let mode = SessionCardSnapshot.Mode(metadataValue: metadataValue([
            "session.mode", "agent.mode", "permissionMode", "permission_mode",
        ]) ?? launchArgumentValue(names: ["--mode", "--permission-mode", "--permissionMode"]))
        let modelName = metadataValue(["session.model", "agent.model", "model"])
            ?? launchArgumentValue(names: ["--model", "-m"])
            ?? launchEnvironmentValue(keys: [
                "CMUX_AGENT_MODEL", "CODEX_MODEL", "OPENAI_MODEL", "ANTHROPIC_MODEL", "CLAUDE_MODEL",
            ])
        let added = metadataValue([
            "session.diff.added", "session.diff.additions", "diff.added", "diff.additions",
        ])
        let deleted = metadataValue([
            "session.diff.deleted", "session.diff.deletions", "diff.deleted", "diff.deletions",
        ])
        let badge = worktreeNumber.map(SessionCardSnapshot.Badge.indexedWorktree)
            ?? .unindexedHost(host)

        return SessionCardSnapshot(
            workspaceNumber: workspaceNumber,
            name: displayName(worktreeNumber: worktreeNumber),
            colorHex: workspace.customColor.flatMap { NSColor(hex: $0) == nil ? nil : $0 }
                ?? "#4493F8",
            host: host,
            branchName: branchName(),
            pullRequests: workspace.sidebarPullRequestsInDisplayOrder().map {
                SessionCardSnapshot.PullRequest(
                    number: $0.number,
                    label: $0.label,
                    url: $0.url,
                    status: $0.status,
                    isStale: $0.isStale
                )
            },
            modelName: modelName,
            mode: mode,
            status: status,
            isPinned: workspace.isPinned,
            diff: SessionCardSnapshot.Diff(
                added: SessionCardSnapshot.Diff.parseCount(added),
                deleted: SessionCardSnapshot.Diff.parseCount(deleted)
            ),
            badge: badge
        )
    }

    private func displayName(worktreeNumber: Int?) -> String {
        var title = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["🖥️", "🖥", "💻", "🖥︎", "📟", "🧑‍💻"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["[devbox]", "[local]", "[laptop]"] where title.lowercased().hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let worktreeNumber {
            for prefix in ["\(worktreeNumber)\u{FE0F}\u{20E3}", "\(worktreeNumber)\u{20E3}"]
            where title.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let numericPrefix = String(worktreeNumber)
            if title.hasPrefix(numericPrefix) {
                let remainder = title.dropFirst(numericPrefix.count)
                if remainder.first?.isWhitespace == true {
                    title = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return title.isEmpty ? workspace.title : title
    }

    private func indexedWorktreeNumber() -> Int? {
        var candidates = [workspace.title, workspace.currentDirectory]
        candidates.append(contentsOf: workspace.panelDirectories.values)
        for paneId in workspace.bonsplitController.allPaneIds {
            candidates.append(contentsOf: workspace.bonsplitController.tabs(inPane: paneId).map(\.title))
        }
        for agent in orderedAgentSnapshots() {
            candidates.append(contentsOf: [
                agent.workingDirectory,
                agent.launchCommand?.workingDirectory,
                agent.launchCommand?.executablePath,
            ].compactMap { $0 })
            candidates.append(contentsOf: agent.launchCommand?.arguments ?? [])
        }
        return candidates.compactMap(SessionCardSnapshot.indexedWorktreeNumber(in:)).first
    }

    private func branchName() -> String? {
        let branches = workspace.sidebarGitBranchesInDisplayOrder().map {
            "\($0.branch)\($0.isDirty ? "*" : "")"
        }
        if !branches.isEmpty { return branches.joined(separator: " | ") }
        return workspace.gitBranch?.branch.nilIfEmpty
    }

    private func metadataValue(_ keys: [String]) -> String? {
        for key in keys {
            if let value = workspace.statusEntries[key]?.value
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func launchArgumentValue(names: [String]) -> String? {
        for agent in orderedAgentSnapshots() {
            let arguments = agent.launchCommand?.arguments ?? []
            for (index, argument) in arguments.enumerated() {
                for name in names {
                    if argument == name, arguments.indices.contains(index + 1) {
                        return arguments[index + 1].nilIfEmpty
                    }
                    if argument.hasPrefix(name + "=") {
                        return String(argument.dropFirst(name.count + 1)).nilIfEmpty
                    }
                }
            }
        }
        return nil
    }

    private func launchEnvironmentValue(keys: [String]) -> String? {
        for agent in orderedAgentSnapshots() {
            let environment = agent.launchCommand?.environment ?? [:]
            for key in keys {
                if let value = environment[key]?.nilIfEmpty { return value }
            }
        }
        return nil
    }

    private func orderedAgentSnapshots() -> [SessionRestorableAgentSnapshot] {
        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        var snapshots: [SessionRestorableAgentSnapshot] = []
        var seenPanelIds = Set<UUID>()
        for panelId in orderedPanelIds {
            guard let snapshot = workspace.restoredAgentSnapshotsByPanelId[panelId] else { continue }
            snapshots.append(snapshot)
            seenPanelIds.insert(panelId)
        }
        snapshots.append(contentsOf: workspace.restoredAgentSnapshotsByPanelId.compactMap { panelId, snapshot in
            seenPanelIds.contains(panelId) ? nil : snapshot
        })
        return snapshots
    }

    private var presentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey {
        Self.presentationKey(settings: settings, showsAgentActivity: showsAgentActivity)
    }

    static func presentationKey(
        settings: SidebarTabItemSettingsSnapshot,
        showsAgentActivity: Bool
    ) -> SidebarWorkspaceSnapshotBuilder.PresentationKey {
        SidebarWorkspaceSnapshotBuilder.PresentationKey(
            showsWorkspaceDescription: settings.showsWorkspaceDescription,
            usesVerticalBranchLayout: settings.branchDirectory.branchLayout == .vertical,
            showsGitBranch: settings.showsGitBranch,
            usesViewportAwarePath: settings.usesLastSegmentPath,
            showsAgentActivity: showsAgentActivity,
            visibleAuxiliaryDetails: settings.visibleAuxiliaryDetails
        )
    }

    private var visibleCustomDescription: String? {
        guard let description = workspace.customDescription else { return nil }
        if workspace.title.hasPrefix("vm:"),
           description.trimmingCharacters(in: .whitespacesAndNewlines)
            == Self.legacyVMWebSocketDescription {
            return nil
        }
        return description
    }

    private var remoteWorkspaceSidebarText: String? {
        guard workspace.isRemoteWorkspace else { return nil }
        let target = workspace.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let target, !target.isEmpty { return target }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "Remote workspace")
    }

    private var copyableSidebarSSHError: String? {
        let target = workspace.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = workspace.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.remoteConnectionState == .error || workspace.remoteConnectionState == .suspended,
           let detail,
           !detail.isEmpty {
            return SidebarRemoteErrorCopySupport.clipboardText(for: [SidebarRemoteErrorCopyEntry(
                workspaceTitle: workspace.title,
                target: target,
                detail: detail
            )])
        }
        if let statusValue = workspace.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            return SidebarRemoteErrorCopySupport.clipboardText(for: [SidebarRemoteErrorCopyEntry(
                workspaceTitle: workspace.title,
                target: target,
                detail: statusValue
            )])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch workspace.remoteConnectionState {
        case .connected:
            return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .reconnecting:
            return String(localized: "remote.status.reconnecting", defaultValue: "Reconnecting")
        case .error:
            return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected:
            return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        case .suspended:
            return String(localized: "remote.status.suspended", defaultValue: "Unreachable")
        }
    }

    private var remoteStateHelpText: String {
        let target = workspace.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = workspace.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch workspace.remoteConnectionState {
        case .connected:
            return remoteHelp("sidebar.remote.help.connected", "Remote connected to %@", target)
        case .connecting:
            return remoteHelp("sidebar.remote.help.connecting", "Remote connecting to %@", target)
        case .reconnecting:
            return remoteHelp("sidebar.remote.help.reconnecting", "Remote reconnecting to %@", target)
        case .error:
            if let detail, !detail.isEmpty {
                return String(
                    format: String(
                        localized: "sidebar.remote.help.errorWithDetail",
                        defaultValue: "Remote error for %@: %@"
                    ),
                    locale: .current,
                    target,
                    detail
                )
            }
            return remoteHelp("sidebar.remote.help.error", "Remote error for %@", target)
        case .disconnected:
            return remoteHelp("sidebar.remote.help.disconnected", "Remote disconnected from %@", target)
        case .suspended:
            return remoteHelp(
                "sidebar.remote.help.suspended",
                "SSH host %@ is unreachable. Automatic reconnect is paused — use Reconnect to retry.",
                target
            )
        }
    }

    private func remoteHelp(
        _ key: StaticString,
        _ fallback: String.LocalizationValue,
        _ target: String
    ) -> String {
        String(
            format: String(localized: key, defaultValue: fallback),
            locale: .current,
            target
        )
    }

    private func compactBranchDirectoryCandidatesList(
        gitSummary: String?,
        directoryCandidates: [String]
    ) -> [String] {
        if directoryCandidates.isEmpty {
            return gitSummary.flatMap { $0.isEmpty ? nil : [$0] } ?? []
        }
        guard let gitSummary, !gitSummary.isEmpty else { return directoryCandidates }
        return directoryCandidates.map { "\(gitSummary) · \($0)" }
    }

    private func gitBranchSummaryText(orderedPanelIds: [UUID]) -> String? {
        let lines = workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map {
            "\($0.branch)\($0.isDirty ? "*" : "")"
        }
        return lines.isEmpty ? nil : lines.joined(separator: " | ")
    }

    private func verticalBranchDirectoryLines(
        orderedPanelIds: [UUID]
    ) -> [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] {
        let entries = workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        let home = SidebarPathFormatter.homeDirectoryPath
        return entries.compactMap { entry in
            let branch: String? = settings.showsGitBranch
                ? entry.branch.map { "\($0)\(entry.isDirty ? "*" : "")" }
                : nil
            let directories: [String]
            if let directory = entry.directory {
                if entry.directoryIsDisplayLabel {
                    directories = [directory]
                } else if settings.usesLastSegmentPath {
                    directories = SidebarPathFormatter.pathCandidates(directory, homeDirectoryPath: home)
                } else {
                    let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                    directories = shortened.isEmpty ? [] : [shortened]
                }
            } else {
                directories = []
            }
            guard branch != nil || !directories.isEmpty else { return nil }
            return SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(
                branch: branch,
                directoryCandidates: directories
            )
        }
    }

    private func compactDirectoryCandidatesList(orderedPanelIds: [UUID]) -> [String] {
        let home = SidebarPathFormatter.homeDirectoryPath
        let directories = workspace.sidebarDisplayedDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        guard !directories.isEmpty else { return [] }
        if !settings.usesLastSegmentPath {
            let joined = directories
                .map {
                    $0.isDisplayLabel
                        ? $0.text
                        : SidebarPathFormatter.shortenedPath($0.text, homeDirectoryPath: home)
                }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            return joined.isEmpty ? [] : [joined]
        }
        let candidates = directories
            .map {
                $0.isDisplayLabel
                    ? [$0.text]
                    : SidebarPathFormatter.pathCandidates($0.text, homeDirectoryPath: home)
            }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return [] }

        var indices = Array(repeating: 0, count: candidates.count)
        var result: [String] = []
        while true {
            let joined = zip(indices, candidates).map { $1[$0] }.joined(separator: " | ")
            if !joined.isEmpty, result.last != joined { result.append(joined) }
            guard let index = indices.indices.last(where: {
                indices[$0] < candidates[$0].count - 1
            }) else { break }
            indices[index] += 1
        }
        return result
    }

    private func pullRequestDisplays(
        orderedPanelIds: [UUID]
    ) -> [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] {
        workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map {
            SidebarWorkspaceSnapshotBuilder.PullRequestDisplay(
                id: "\($0.label.lowercased())#\($0.number)|\($0.url.absoluteString)",
                number: $0.number,
                label: $0.label,
                url: $0.url,
                status: $0.status,
                isStale: $0.isStale
            )
        }
    }
}

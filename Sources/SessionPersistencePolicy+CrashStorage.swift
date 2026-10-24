import Foundation
import CmuxTerminalCore
import CmuxWorkspaces

extension SessionPersistencePolicy {
    static func defaultCmuxCrashDirectoryURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("crash", isDirectory: true)
    }

    static func cmuxCrashDirectoryURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var urls = [defaultCmuxCrashDirectoryURL(homeDirectory: homeDirectory)]
        if let xdgStateHome = environment["XDG_STATE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgStateHome.isEmpty {
            urls.append(
                URL(fileURLWithPath: (xdgStateHome as NSString).expandingTildeInPath, isDirectory: true)
                    .appendingPathComponent("cmux", isDirectory: true)
                    .appendingPathComponent("crash", isDirectory: true)
            )
        }

        var seen: Set<String> = []
        return urls.filter { url in
            seen.insert(standardizedPath(url.path(percentEncoded: false))).inserted
        }
    }

    static func isCmuxCrashStorageURL(
        _ url: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard url.isFileURL else { return false }
        return isCmuxCrashStoragePath(
            url.path(percentEncoded: false),
            homeDirectory: homeDirectory,
            environment: environment
        )
    }

    static func isCmuxCrashStoragePath(
        _ path: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }
        let crashDirectoryComponents = cmuxCrashDirectoryURLs(homeDirectory: homeDirectory, environment: environment)
            .map { pathComponents(for: $0.path(percentEncoded: false)) }
        var pathCache: [String: Bool] = [:]
        return isCmuxCrashStoragePath(
            trimmedPath,
            crashDirectoryComponents: crashDirectoryComponents,
            pathCache: &pathCache
        )
    }

    static func pruningCmuxCrashDiagnosticWindows(
        from snapshot: AppSessionSnapshot,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (snapshot: AppSessionSnapshot?, removedAny: Bool) {
        let crashDirectoryComponents = cmuxCrashDirectoryURLs(homeDirectory: homeDirectory, environment: environment)
            .map { pathComponents(for: $0.path(percentEncoded: false)) }
        var removedAny = false
        var pathCache: [String: Bool] = [:]
        var windows: [SessionWindowSnapshot] = []
        var phantomWindowCount = 0
        for window in snapshot.windows {
            // A window with no workspaces and no window Dock is a phantom "empty
            // shell" (seen after an unclean shutdown, #6646). Restoring it still
            // builds a real NSWindow, and several at launch have been reported to
            // wedge the WindowServer, so it is never persisted or replayed.
            // Dropping one is not crash-diagnostic data: `removedAny` stays false
            // so save paths do not delete the primary or set the crash-only marker.
            guard !window.isPhantomSessionWindow else {
                phantomWindowCount += 1
                continue
            }
            let result = pruningCmuxCrashDiagnosticWorkspaces(
                from: window,
                crashDirectoryComponents: crashDirectoryComponents,
                pathCache: &pathCache
            )
            removedAny = removedAny || result.removedAny
            if let window = result.window {
                windows.append(window)
            }
        }

        if windows.count + phantomWindowCount != snapshot.windows.count {
            removedAny = true
        }
        guard !windows.isEmpty else {
            return (nil, removedAny)
        }

        var pruned = snapshot
        pruned.windows = windows
        return (pruned, removedAny)
    }

    /// The snapshot a live restore opens: crash-diagnostic windows pruned,
    /// scrollback recovered (when given), then crash-duplicate windows
    /// merged. Every live restore uses it: the automatic startup restore and
    /// its history fallback, the manual reopen, and `restore-session` import.
    /// Nil when nothing restorable is left.
    static func snapshotForLiveRestore(
        _ snapshot: AppSessionSnapshot,
        recoveringScrollback: (AppSessionSnapshot) -> AppSessionSnapshot = { $0 }
    ) -> AppSessionSnapshot? {
        guard let pruned = pruningCmuxCrashDiagnosticWindows(from: snapshot).snapshot else {
            return nil
        }
        return mergingCrashDuplicateWindows(in: recoveringScrollback(pruned)).snapshot
    }

    /// Merges the windows a crash wrote twice, before restore opens them.
    ///
    /// A crash can leave the same window in the snapshot twice, sometimes
    /// under a new window ID; restoring both opens every workspace twice.
    /// `CrashWindowSignature.isCrashDuplicate(of:)` decides which windows are the same, using
    /// agent checkpoints only (see `workspaceCheckpointIDs`). For each pair:
    /// - The window with the higher restore-fidelity score keeps its window
    ///   ID, frame, display and sidebar.
    /// - Workspaces are matched whole, by stable ID, workspace ID, agent
    ///   checkpoints (one copy's set contains the other's), or a unique title
    ///   in the same directory; never by position. A workspace found in only
    ///   one copy is appended.
    /// - Of two matched workspaces one is kept whole and the other dropped,
    ///   with its unique panels (plain terminals, browsers, splits): the copy
    ///   whose agent checkpoints strictly contain the other's, otherwise the
    ///   one with the higher fidelity score.
    /// - Three or more copies of a window collapse into one, pair by pair.
    ///
    /// Only the live restore merges; pruning and the manual-restore sync
    /// don't, so the launch's `-previous` copy and rotated history keep every
    /// window. The restored layout is saved afterwards like any other: the
    /// overwrite guard holds poorer saves for up to its 5-minute maturity
    /// window, then autosave writes the merged layout, and the next launch
    /// copies it into `-previous`.
    static func mergingCrashDuplicateWindows(
        in snapshot: AppSessionSnapshot
    ) -> (snapshot: AppSessionSnapshot, mergedWindowCount: Int) {
        var result: [SessionWindowSnapshot] = []
        var signatures: [CrashWindowSignature] = []
        result.reserveCapacity(snapshot.windows.count)
        var merged = 0
        for window in snapshot.windows {
            let signature = crashWindowSignature(window)
            if let index = signatures.firstIndex(where: {
                $0.isCrashDuplicate(of: signature)
            }) {
                result[index] = mergingCrashDuplicateWindows(result[index], window)
                signatures[index] = crashWindowSignature(result[index])
                merged += 1
                continue
            }
            result.append(window)
            signatures.append(signature)
        }
        guard merged > 0 else { return (snapshot, 0) }
        var deduplicated = snapshot
        deduplicated.windows = result
        return (deduplicated, merged)
    }

    private static func crashWindowSignature(
        _ window: SessionWindowSnapshot
    ) -> CrashWindowSignature {
        let workspaces = window.tabManager.workspaces
        let workspaceIDs = workspaces.compactMap(\.workspaceId)
        let titles = workspaces.compactMap { workspace -> String? in
            let title = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? nil : title
        }
        return CrashWindowSignature(
            windowId: window.windowId,
            workspaceCount: workspaces.count,
            workspaceIDs: workspaceIDs.count == workspaces.count ? workspaceIDs : nil,
            checkpointIDs: crashWindowCheckpointIDs(window),
            workspaceTitles: titles
        )
    }

    /// Merge two crash-window generations that share at least one checkpoint.
    /// A later save can contain an additional workspace while the older copy
    /// still carries a useful plain terminal. Keep the richer copy of an
    /// overlapping workspace and append workspaces that exist only in the
    /// other generation instead of dropping them with the duplicate window.
    private static func mergingCrashDuplicateWindows(
        _ lhs: SessionWindowSnapshot,
        _ rhs: SessionWindowSnapshot
    ) -> SessionWindowSnapshot {
        let lhsIsRicher = sessionWindowRestoreFidelityScore(lhs) >=
            sessionWindowRestoreFidelityScore(rhs)
        let preferred = lhsIsRicher ? lhs : rhs
        let supplemental = lhsIsRicher ? rhs : lhs
        var mergedWorkspaces = preferred.tabManager.workspaces

        for workspace in supplemental.tabManager.workspaces {
            let supplementalCheckpoints = workspaceCheckpointIDs(workspace)
            if let matchingIndex = duplicateWorkspaceMatchIndex(
                workspace,
                in: mergedWorkspaces,
                checkpoints: supplementalCheckpoints
            ) {
                if prefersCrashWorkspaceCopy(workspace, over: mergedWorkspaces[matchingIndex]) {
                    mergedWorkspaces[matchingIndex] = workspace
                }
            } else {
                mergedWorkspaces.append(workspace)
            }
        }

        var merged = preferred
        merged.tabManager.workspaces = mergedWorkspaces
        var mergedGroups = preferred.tabManager.workspaceGroups ?? []
        for group in supplemental.tabManager.workspaceGroups ?? [] {
            if !mergedGroups.contains(where: { $0.id == group.id }) {
                mergedGroups.append(group)
            }
        }
        merged.tabManager.workspaceGroups = mergedGroups.isEmpty ? nil : mergedGroups
        return merged
    }

    /// The copy whose agent checkpoints strictly contain the other's wins, so
    /// an agent pane found in only one copy is never dropped; otherwise the
    /// higher fidelity score wins.
    private static func prefersCrashWorkspaceCopy(
        _ candidate: SessionWorkspaceSnapshot,
        over existing: SessionWorkspaceSnapshot
    ) -> Bool {
        let candidateAgents = workspaceCheckpointIDs(candidate)
        let existingAgents = workspaceCheckpointIDs(existing)
        if candidateAgents != existingAgents {
            if existingAgents.isStrictSubset(of: candidateAgents) { return true }
            if candidateAgents.isStrictSubset(of: existingAgents) { return false }
        }
        return sessionWorkspaceRestoreFidelityScore(candidate) >
            sessionWorkspaceRestoreFidelityScore(existing)
    }

    private static func duplicateWorkspaceMatchIndex(
        _ workspace: SessionWorkspaceSnapshot,
        in existing: [SessionWorkspaceSnapshot],
        checkpoints: Set<String>
    ) -> Int? {
        if let stableId = workspace.stableId,
           let index = existing.firstIndex(where: { $0.stableId == stableId }) {
            return index
        }
        if let workspaceId = workspace.workspaceId,
           let index = existing.firstIndex(where: { $0.workspaceId == workspaceId }) {
            return index
        }
        if !checkpoints.isEmpty,
           let index = existing.firstIndex(where: { current in
               let currentCheckpoints = workspaceCheckpointIDs(current)
               guard !currentCheckpoints.isEmpty else { return false }
               // A shared checkpoint is enough only when one snapshot is a
               // complete generation of the other. Partial overlap can mean
               // two different worktrees and must remain two workspaces.
               return checkpoints == currentCheckpoints
                   || checkpoints.isSubset(of: currentCheckpoints)
                   || currentCheckpoints.isSubset(of: checkpoints)
           }) {
            return index
        }
        if let title = workspace.customTitle,
           !title.isEmpty {
            let titled = existing.indices.filter { index in
                existing[index].customTitle == title &&
                    existing[index].customDescription == workspace.customDescription &&
                    identitylessWorkspaceDirectoriesMatch(workspace, existing[index])
            }
            if titled.count == 1 {
                return titled[0]
            }
        }

        // Legacy snapshots often omit workspace identities and titles. Array
        // position is not an identity: crash generations can reorder tabs, so
        // guessing here can merge two unrelated worktrees and silently discard
        // one of them. Keep the supplemental workspace instead; only a stable
        // identity, checkpoint, or unique title is safe to merge.
        return nil
    }

    /// A title is only a safe identity fallback when both identity-less
    /// workspaces still point at the same working directory. A user can have
    /// two intentionally separate workspaces with the same title, and merging
    /// those would move panels (and their restored agents) between worktrees.
    private static func identitylessWorkspaceDirectoriesMatch(
        _ lhs: SessionWorkspaceSnapshot,
        _ rhs: SessionWorkspaceSnapshot
    ) -> Bool {
        guard !lhs.currentDirectory.isEmpty, !rhs.currentDirectory.isEmpty else {
            return false
        }
        return standardizedWorkspacePath(lhs.currentDirectory) ==
            standardizedWorkspacePath(rhs.currentDirectory)
    }

    private static func standardizedWorkspacePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func crashWindowCheckpointIDs(
        _ window: SessionWindowSnapshot
    ) -> Set<String> {
        Set(window.tabManager.workspaces.flatMap(workspaceCheckpointIDs))
    }

    /// Agent sessions only: the restorable agent's session ID, an agent-hook
    /// resume binding, or the managed-agent binding. One agent session runs
    /// in one place, which is what makes a shared checkpoint evidence of a
    /// duplicate. The rare exception is a Claude or Codex session resumed in
    /// two panes without forking, which keeps one session ID in both; that
    /// is deliberate sharing, and two such windows only merge when their
    /// titles and workspace counts match too. Excluded: process-detected
    /// bindings (tmux and herdr session names, which two real windows can
    /// share) and bindings from an untrusted `restore-session` import.
    /// A panel whose agent left no checkpoint contributes nothing, so partial
    /// metadata can only make a merge less likely.
    private static func workspaceCheckpointIDs(
        _ workspace: SessionWorkspaceSnapshot
    ) -> Set<String> {
        Set(workspace.panels.compactMap { panel in
            guard let terminal = panel.terminal else { return nil }
            if let sessionId = terminal.agent?.sessionId { return sessionId }
            if let binding = terminal.resumeBinding, binding.isAgentHookBinding,
               let checkpoint = binding.checkpointId {
                return checkpoint
            }
            guard let managed = terminal.managedAgentResumeBinding,
                  !managed.isProcessDetected,
                  managed.source != SurfaceResumeBindingSnapshot.untrustedSessionImportSource else {
                return nil
            }
            return managed.checkpointId
        })
    }

    private static func sessionWindowRestoreFidelityScore(_ window: SessionWindowSnapshot) -> Int {
        window.tabManager.workspaces.reduce(0) { $0 + sessionWorkspaceRestoreFidelityScore($1) }
    }

    private static func sessionWorkspaceRestoreFidelityScore(
        _ workspace: SessionWorkspaceSnapshot
    ) -> Int {
        workspace.panels.reduce(
            (workspace.workspaceId == nil ? 0 : 1) +
                (workspace.currentDirectory.isEmpty ? 0 : 1)
        ) { score, panel in
            let binding = panel.terminal?.resumeBinding ?? panel.terminal?.managedAgentResumeBinding
            return score
                + (panel.directory == nil ? 0 : 1)
                + (panel.terminal?.workingDirectory == nil ? 0 : 4)
                + (panel.terminal?.agent?.workingDirectory == nil ? 0 : 4)
                + (panel.terminal?.agent?.launchCommand == nil ? 0 : 3)
                + (binding?.cwd == nil ? 0 : 3)
                + (binding?.launchCommand == nil ? 0 : 2)
                + (binding?.isAgentHookBinding == true ? 2 : 0)
        }
    }

    static func isCmuxCrashDiagnosticWindow(
        _ window: SessionWindowSnapshot,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let crashDirectoryComponents = cmuxCrashDirectoryURLs(homeDirectory: homeDirectory, environment: environment)
            .map { pathComponents(for: $0.path(percentEncoded: false)) }
        let workspaces = window.tabManager.workspaces
        guard !workspaces.isEmpty else { return false }
        var pathCache: [String: Bool] = [:]
        for workspace in workspaces {
            guard isCmuxCrashDiagnosticWorkspace(
                workspace,
                crashDirectoryComponents: crashDirectoryComponents,
                pathCache: &pathCache
            ) else {
                return false
            }
        }
        return true
    }

    private static func pruningCmuxCrashDiagnosticWorkspaces(
        from window: SessionWindowSnapshot,
        crashDirectoryComponents: [[String]],
        pathCache: inout [String: Bool]
    ) -> (window: SessionWindowSnapshot?, removedAny: Bool) {
        let originalWorkspaces = window.tabManager.workspaces
        var kept: [(offset: Int, element: SessionWorkspaceSnapshot)] = []
        for (offset, workspace) in originalWorkspaces.enumerated() {
            if !isCmuxCrashDiagnosticWorkspace(
                workspace,
                crashDirectoryComponents: crashDirectoryComponents,
                pathCache: &pathCache
            ) {
                kept.append((offset, workspace))
            }
        }

        guard kept.count != originalWorkspaces.count else { return (window, false) }
        guard !kept.isEmpty else { return (nil, true) }

        var prunedWindow = window
        var tabManager = window.tabManager
        let keptOriginalIndices = kept.map { $0.offset }
        let keptWorkspaces = kept.map { $0.element }
        tabManager.workspaces = keptWorkspaces
        tabManager.selectedWorkspaceIndex = adjustedSelectedWorkspaceIndex(
            original: window.tabManager.selectedWorkspaceIndex,
            keptOriginalIndices: keptOriginalIndices
        )
        tabManager.workspaceGroups = pruningWorkspaceGroups(
            window.tabManager.workspaceGroups,
            originalWorkspaces: originalWorkspaces,
            keptWorkspaces: keptWorkspaces
        )
        prunedWindow.tabManager = tabManager
        return (prunedWindow, true)
    }

    private static func isCmuxCrashDiagnosticWorkspace(
        _ workspace: SessionWorkspaceSnapshot,
        crashDirectoryComponents: [[String]],
        pathCache: inout [String: Bool]
    ) -> Bool {
        guard workspace.remote == nil else { return false }
        guard !workspaceCarriesRestorableUserState(workspace) else { return false }
        if workspace.panels.isEmpty {
            return isCmuxCrashStoragePath(
                workspace.currentDirectory,
                crashDirectoryComponents: crashDirectoryComponents,
                pathCache: &pathCache
            )
        }
        guard workspace.panels.allSatisfy(isPlainLocalTerminalPanel) else { return false }

        let paths = ([workspace.currentDirectory] + workspace.panels.flatMap { panel in
            [panel.directory, panel.terminal?.workingDirectory].compactMap { $0 }
        })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        guard !paths.isEmpty else { return false }
        for path in paths {
            guard isCmuxCrashStoragePath(
                path,
                crashDirectoryComponents: crashDirectoryComponents,
                pathCache: &pathCache
            ) else {
                return false
            }
        }
        return true
    }

    private static func isPlainLocalTerminalPanel(_ panel: SessionPanelSnapshot) -> Bool {
        guard case .terminal = panel.type,
              let terminal = panel.terminal else {
            return false
        }
        guard !panelCarriesRestorableUserState(panel),
              !terminalCarriesRestorableUserState(terminal) else {
            return false
        }
        guard terminal.agent == nil,
              terminal.hibernation == nil,
              terminal.resumeBinding == nil,
              isNilOrBlank(terminal.tmuxStartCommand),
              terminal.isRemoteTerminal != true,
              isNilOrBlank(terminal.remotePTYSessionID) else {
            return false
        }
        return true
    }

    private static func workspaceCarriesRestorableUserState(_ workspace: SessionWorkspaceSnapshot) -> Bool {
        if !isNilOrBlank(workspace.customTitle)
            || !isNilOrBlank(workspace.customDescription)
            || !isNilOrBlank(workspace.customColor)
            || workspace.isPinned
            || workspace.groupId != nil
            || workspace.isManuallyUnread == true
            || workspace.hasUnreadIndicator == true
            || workspace.progress != nil
            || workspace.gitBranch != nil {
            return true
        }
        if workspace.notifications?.isEmpty == false
            || workspace.canvasPanes?.isEmpty == false
            || workspace.environment?.isEmpty == false
            || !workspace.statusEntries.isEmpty
            || !workspace.logEntries.isEmpty {
            return true
        }
        return false
    }

    private static func panelCarriesRestorableUserState(_ panel: SessionPanelSnapshot) -> Bool {
        if !isNilOrBlank(panel.customTitle)
            || panel.isPinned
            || panel.isManuallyUnread
            || panel.hasUnreadIndicator == true
            || panel.restoredUnreadContributesToWorkspace == true
            || panel.gitBranch != nil
            || !panel.listeningPorts.isEmpty {
            return true
        }
        if panel.notifications?.isEmpty == false {
            return true
        }
        return false
    }

    private static func terminalCarriesRestorableUserState(_ terminal: SessionTerminalPanelSnapshot) -> Bool {
        if let fontSize = terminal.fontSize,
           TerminalFontSizePolicy().acceptsPersistedBasePoints(fontSize) {
            return true
        }
        return !isNilOrBlank(terminal.scrollback) || terminal.textBoxDraft != nil
    }

    private static func adjustedSelectedWorkspaceIndex(
        original: Int?,
        keptOriginalIndices: [Int]
    ) -> Int? {
        guard !keptOriginalIndices.isEmpty else { return nil }
        guard let original else { return nil }
        if let exact = keptOriginalIndices.firstIndex(of: original) {
            return exact
        }
        return keptOriginalIndices.lastIndex(where: { $0 < original }) ?? 0
    }

    private static func pruningWorkspaceGroups(
        _ groups: [SessionWorkspaceGroupSnapshot]?,
        originalWorkspaces: [SessionWorkspaceSnapshot],
        keptWorkspaces: [SessionWorkspaceSnapshot]
    ) -> [SessionWorkspaceGroupSnapshot]? {
        guard let groups else { return nil }
        let originalMembersByGroupId = Dictionary(grouping: originalWorkspaces, by: \.groupId)
        let keptMembersByGroupId = Dictionary(grouping: keptWorkspaces, by: \.groupId)
        let occupiedGroupIds = Set(keptMembersByGroupId.keys.compactMap { $0 })
        let pruned = groups.compactMap { group -> SessionWorkspaceGroupSnapshot? in
            let keepsEmptyPinnedGroup = group.isPinned == true && group.anchorIsEmpty == true
            guard occupiedGroupIds.contains(group.id) || keepsEmptyPinnedGroup else { return nil }
            let groupId = Optional(group.id)
            let originalMembers = originalMembersByGroupId[groupId] ?? []
            let keptMembers = keptMembersByGroupId[groupId] ?? []
            if keptMembers.isEmpty {
                return keepsEmptyPinnedGroup ? group : nil
            }

            var copy = group
            let originalAnchorWorkspaceId = group.anchorWorkspaceId ?? group.anchorMemberIndex.flatMap { index in
                originalMembers.indices.contains(index) ? originalMembers[index].workspaceId : nil
            }
            let newAnchorIndex = originalAnchorWorkspaceId.flatMap { anchorId in
                keptMembers.firstIndex { $0.workspaceId == anchorId }
            } ?? 0
            copy.anchorMemberIndex = newAnchorIndex
            copy.anchorWorkspaceId = keptMembers[newAnchorIndex].workspaceId
            copy.anchorIsEmpty = nil
            return copy
        }
        return pruned.isEmpty ? nil : pruned
    }

    private static func isCmuxCrashStoragePath(
        _ path: String,
        crashDirectoryComponents: [[String]],
        pathCache: inout [String: Bool]
    ) -> Bool {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return false }
        let candidatePath = standardizedPath(trimmedPath)
        if let cached = pathCache[candidatePath] {
            return cached
        }
        let candidateComponents = pathComponents(for: candidatePath)
        guard !candidateComponents.isEmpty else {
            pathCache[candidatePath] = false
            return false
        }
        if isPathComponents(candidateComponents, inAnyCrashDirectory: crashDirectoryComponents) {
            pathCache[candidatePath] = true
            return true
        }

        pathCache[candidatePath] = false
        return false
    }

    private static func isPathComponents(
        _ candidateComponents: [String],
        inAnyCrashDirectory crashDirectoryComponents: [[String]]
    ) -> Bool {
        crashDirectoryComponents.contains { crashComponents in
            guard candidateComponents.count >= crashComponents.count else { return false }
            return Array(candidateComponents.prefix(crashComponents.count)) == crashComponents
        }
    }

    private static func pathComponents(for path: String) -> [String] {
        URL(fileURLWithPath: standardizedPath(path)).pathComponents
    }

    private static func standardizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func isNilOrBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

extension SessionWindowSnapshot {
    /// Whether this window carries nothing to restore: no workspaces, no
    /// window Dock, and no empty pinned group (which `TabManager` persists and
    /// restores without a member). See
    /// `SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows`.
    var isPhantomSessionWindow: Bool {
        guard tabManager.workspaces.isEmpty, dock == nil else { return false }
        let hasEmptyPinnedGroup = tabManager.workspaceGroups?.contains {
            $0.isPinned == true && $0.anchorIsEmpty == true
        } ?? false
        return !hasEmptyPinnedGroup
    }
}

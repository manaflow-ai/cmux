import Foundation
import CmuxTerminalCore

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
        let deduplicated = deduplicatingSessionWindows(windows)
        removedAny = removedAny || deduplicated.removedAny
        windows = deduplicated.windows
        guard !windows.isEmpty else {
            return (nil, removedAny)
        }

        var pruned = snapshot
        pruned.windows = windows
        return (pruned, removedAny)
    }

    /// A crash can leave the same window manifest written twice. Replaying both
    /// copies creates a second set of panels; agent admission suppresses
    /// duplicate providers, but the resulting empty/stale tabs still consume
    /// UI and persistence resources. Some crash snapshots preserve workspace
    /// identities in both copies, while others preserve only the same agent
    /// checkpoint sequence. In the latter case the panel checkpoint sequence
    /// is the stable identity and the richer copy must win.
    private struct SessionWindowDuplicateFingerprint: Hashable {
        var workspaceIDs: [UUID]?
        var agentSessionIDs: [String]?
        var workspaceCount: Int
        var panelCount: Int
    }

    private static func deduplicatingSessionWindows(
        _ windows: [SessionWindowSnapshot]
    ) -> (windows: [SessionWindowSnapshot], removedAny: Bool) {
        var seenFingerprints: [SessionWindowDuplicateFingerprint: Int] = [:]
        var result: [SessionWindowSnapshot] = []
        result.reserveCapacity(windows.count)
        var removedAny = false

        for window in windows {
            let workspaceIDs = window.tabManager.workspaces.compactMap(\.workspaceId)
            let hasCompleteIdentitySequence = workspaceIDs.count == window.tabManager.workspaces.count
                && !workspaceIDs.isEmpty
            let panelCount = window.tabManager.workspaces.reduce(into: 0) { count, workspace in
                count += workspace.panels.count
            }
            let agentSessionIDs = window.tabManager.workspaces.flatMap { workspace in
                workspace.panels.compactMap { panel -> String? in
                    guard let terminal = panel.terminal else { return nil }
                    return terminal.agent?.sessionId
                        ?? terminal.resumeBinding?.checkpointId
                        ?? terminal.managedAgentResumeBinding?.checkpointId
                }
            }.reduce(into: Set<String>()) { $0.insert($1) }.sorted()
            let fingerprint: SessionWindowDuplicateFingerprint?
            if !agentSessionIDs.isEmpty {
                fingerprint = SessionWindowDuplicateFingerprint(
                    workspaceIDs: nil,
                    agentSessionIDs: agentSessionIDs,
                    workspaceCount: window.tabManager.workspaces.count,
                    panelCount: panelCount
                )
            } else if hasCompleteIdentitySequence {
                fingerprint = SessionWindowDuplicateFingerprint(
                    workspaceIDs: workspaceIDs,
                    agentSessionIDs: nil,
                    workspaceCount: window.tabManager.workspaces.count,
                    panelCount: panelCount
                )
            } else {
                fingerprint = nil
            }

            guard let fingerprint else {
                result.append(window)
                continue
            }
            if let existingIndex = seenFingerprints[fingerprint] {
                // Equal fingerprints identify a shared checkpoint manifest,
                // not necessarily identical workspace contents. Merge both
                // generations so identity-less workspaces are retained while
                // richer copies still win for the same workspace.
                result[existingIndex] = mergingCrashDuplicateWindows(
                    result[existingIndex],
                    window
                )
                removedAny = true
                continue
            }

            // A crash can write two generations of the same window. The later
            // generation may contain additional agent checkpoints, so its
            // fingerprint is not byte-for-byte equal to the earlier one. When
            // both generations have the same workspace cardinality and the
            // exact checkpoint set, they are still the same window. Unique
            // checkpoint sets remain separate so no worktree is discarded.
            if let existingIndex = result.firstIndex(where: {
                areCrashDuplicateWindows($0, window)
            }) {
                result[existingIndex] = mergingCrashDuplicateWindows(
                    result[existingIndex],
                    window
                )
                removedAny = true
                continue
            }
            seenFingerprints[fingerprint] = result.count
            result.append(window)
        }
        return (result, removedAny)
    }

    private static func areCrashDuplicateWindows(
        _ lhs: SessionWindowSnapshot,
        _ rhs: SessionWindowSnapshot
    ) -> Bool {
        guard lhs.tabManager.workspaces.count == rhs.tabManager.workspaces.count,
              lhs.tabManager.workspaces.count > 1 else {
            return false
        }

        let lhsAgents = crashWindowCheckpointIDs(lhs)
        let rhsAgents = crashWindowCheckpointIDs(rhs)
        guard !lhsAgents.isEmpty, !rhsAgents.isEmpty else { return false }
        let overlap = lhsAgents.intersection(rhsAgents)
        if lhsAgents == rhsAgents {
            return true
        }

        // Some crash generations reorder identity-less workspaces and add a
        // small number of newer checkpoints. The workspace titles remain the
        // stable window-level signature in that case. Require a near-complete
        // title multiset and high checkpoint overlap before treating them as
        // duplicate generations; unrelated windows remain separate.
        let lhsTitles = lhs.tabManager.workspaces.compactMap { title -> String? in
            let value = title.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let rhsTitles = rhs.tabManager.workspaces.compactMap { title -> String? in
            let value = title.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        guard lhsTitles.count >= max(3, lhs.tabManager.workspaces.count - 2),
              lhsTitles.count == rhsTitles.count,
              lhsTitles.sorted() == rhsTitles.sorted() else {
            return false
        }
        let overlapRatio = Double(overlap.count) / Double(min(lhsAgents.count, rhsAgents.count))
        // Keep the threshold high enough to reject a one-checkpoint coincidence
        // while allowing one newly-added checkpoint in a reordered four-panel
        // crash generation.
        return overlapRatio >= 0.75
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
                if sessionWorkspaceRestoreFidelityScore(workspace) >
                    sessionWorkspaceRestoreFidelityScore(mergedWorkspaces[matchingIndex]) {
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
                    existing[index].customDescription == workspace.customDescription
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

    private static func crashWindowCheckpointIDs(
        _ window: SessionWindowSnapshot
    ) -> Set<String> {
        Set(window.tabManager.workspaces.flatMap(workspaceCheckpointIDs))
    }

    private static func workspaceCheckpointIDs(
        _ workspace: SessionWorkspaceSnapshot
    ) -> Set<String> {
        Set(workspace.panels.compactMap { panel in
            guard let terminal = panel.terminal else { return nil }
            return terminal.agent?.sessionId
                ?? terminal.resumeBinding?.checkpointId
                ?? terminal.managedAgentResumeBinding?.checkpointId
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

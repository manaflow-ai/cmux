import Foundation

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
        for window in snapshot.windows {
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

        if windows.count != snapshot.windows.count {
            removedAny = true
        }
        guard !windows.isEmpty else {
            return (nil, removedAny)
        }

        var pruned = snapshot
        pruned.windows = windows
        return (pruned, removedAny)
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
              terminal.resumeBindingHistory?.isEmpty != false,
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
        !isNilOrBlank(terminal.scrollback) || terminal.textBoxDraft != nil
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
            guard occupiedGroupIds.contains(group.id) else { return nil }
            let groupId = Optional(group.id)
            let originalMembers = originalMembersByGroupId[groupId] ?? []
            let keptMembers = keptMembersByGroupId[groupId] ?? []
            guard !keptMembers.isEmpty else { return nil }

            var copy = group
            let originalAnchorWorkspaceId = group.anchorWorkspaceId ?? group.anchorMemberIndex.flatMap { index in
                originalMembers.indices.contains(index) ? originalMembers[index].workspaceId : nil
            }
            let newAnchorIndex = originalAnchorWorkspaceId.flatMap { anchorId in
                keptMembers.firstIndex { $0.workspaceId == anchorId }
            } ?? 0
            copy.anchorMemberIndex = newAnchorIndex
            copy.anchorWorkspaceId = keptMembers[newAnchorIndex].workspaceId
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

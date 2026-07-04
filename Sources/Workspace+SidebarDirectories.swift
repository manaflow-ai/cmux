import Combine
import Foundation
import CmuxSidebar

extension Workspace {
    private func normalizedSidebarDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var reportedRemoteCurrentDirectory: String? {
        if let focusedPanelId {
            return reportedPanelDirectory(panelId: focusedPanelId)
        }
        let activeRemotePanelIds = panels.keys.filter { isRemoteTerminalSurface($0) }
        guard !activeRemotePanelIds.isEmpty else { return nil }
        let reportedDirectories = activeRemotePanelIds.compactMap { reportedPanelDirectory(panelId: $0) }
        guard reportedDirectories.count == activeRemotePanelIds.count else { return nil }
        let directories = Set(reportedDirectories)
        return directories.count == 1 ? directories.first : nil
    }

    var presentedCurrentDirectory: String? {
        isRemoteWorkspace ? reportedRemoteCurrentDirectory : normalizedSidebarDirectory(currentDirectory)
    }

    func reportedPanelDirectory(panelId: UUID) -> String? {
        if !allowsLocalDirectoryFallback(panelId: panelId) {
            guard remoteDirectoryReportPanelIds.contains(panelId) else { return nil }
        }
        return normalizedSidebarDirectory(panelDirectories[panelId])
    }

    func allowsLocalDirectoryFallback(panelId: UUID) -> Bool {
        !isRemoteWorkspace ||
            (!remoteDirectoryTrustRequiredPanelIds.contains(panelId) && !isRemoteTerminalSurface(panelId))
    }

    func currentDirectoryChangeRevisionPublisher() -> AnyPublisher<UInt64, Never> {
        NotificationCenter.default
            .publisher(for: .workspaceCurrentDirectoryDidChange)
            .filter { [weak self] notification in
                guard let self else { return false }
                return notification.userInfo?["workspaceId"] as? UUID == self.id &&
                    notification.userInfo?["presentedDirectoryOnly"] as? Bool == true
            }
            .map { _ in () }
            .scan(UInt64(0)) { revision, _ in revision &+ 1 }
            .prepend(0)
            .eraseToAnyPublisher()
    }

    private func sidebarHomeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        guard isRemoteWorkspace else { return FileManager.default.homeDirectoryForCurrentUser.path }
        return SidebarBranchOrdering().inferredRemoteHomeDirectory(
            from: Array(resolvedPanelDirectories.values),
            fallbackDirectory: reportedRemoteCurrentDirectory
        )
    }

    private func sidebarResolvedDirectory(for panelId: UUID) -> String? {
        if let directory = reportedPanelDirectory(panelId: panelId) {
            return directory
        }
        guard allowsLocalDirectoryFallback(panelId: panelId) else { return nil }
        if let requestedDirectory = normalizedSidebarDirectory(
            terminalPanel(for: panelId)?.requestedWorkingDirectory
        ) {
            return requestedDirectory
        }
        guard panelId == focusedPanelId else { return nil }
        return normalizedSidebarDirectory(currentDirectory)
    }

    private func sidebarResolvedPanelDirectories(orderedPanelIds: [UUID]) -> [UUID: String] {
        var resolved: [UUID: String] = [:]
        for panelId in orderedPanelIds {
            if let directory = sidebarResolvedDirectory(for: panelId) {
                resolved[panelId] = directory
            }
        }
        return resolved
    }

    /// One sidebar directory row: the text to render and whether it is a reporter-supplied display label.
    struct SidebarDisplayedDirectory: Equatable {
        let text: String
        let isDisplayLabel: Bool
    }

    func sidebarDirectoriesInDisplayOrder(orderedPanelIds: [UUID], includeFallback: Bool = true) -> [String] {
        sidebarDisplayedDirectoriesInDisplayOrder(
            orderedPanelIds: orderedPanelIds,
            includeFallback: includeFallback
        ).map(\.text)
    }

    func sidebarDisplayedDirectoriesInDisplayOrder(
        orderedPanelIds: [UUID],
        includeFallback: Bool = true
    ) -> [SidebarDisplayedDirectory] {
        sidebarOrderedUniqueDirectories(
            orderedPanelIds: orderedPanelIds,
            includeFallback: includeFallback,
            preferDisplayLabels: true
        )
    }

    func sidebarFilesystemDirectoriesInDisplayOrder(orderedPanelIds: [UUID], includeFallback: Bool = true) -> [String] {
        sidebarOrderedUniqueDirectories(
            orderedPanelIds: orderedPanelIds,
            includeFallback: includeFallback,
            preferDisplayLabels: false
        ).map(\.text)
    }

    func sidebarFilesystemDirectoriesInDisplayOrder() -> [String] {
        sidebarFilesystemDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    private func sidebarOrderedUniqueDirectories(
        orderedPanelIds: [UUID],
        includeFallback: Bool,
        preferDisplayLabels: Bool
    ) -> [SidebarDisplayedDirectory] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        let homeDirectoryForCanonicalization = sidebarHomeDirectoryForCanonicalization(
            resolvedPanelDirectories: resolvedDirectories
        )
        var ordered: [SidebarDisplayedDirectory] = []
        var orderedIndexByKey: [String: Int] = [:]

        for panelId in orderedPanelIds {
            guard let directory = resolvedDirectories[panelId],
                  let key = SidebarBranchOrdering().canonicalDirectoryKey(
                      directory,
                      homeDirectoryForTildeExpansion: homeDirectoryForCanonicalization
                  ) else { continue }
            let displayLabel = preferDisplayLabels
                ? normalizedSidebarDirectory(panelDirectoryDisplayLabels[panelId])
                : nil
            if let existingIndex = orderedIndexByKey[key] {
                if let displayLabel, !ordered[existingIndex].isDisplayLabel {
                    ordered[existingIndex] = SidebarDisplayedDirectory(text: displayLabel, isDisplayLabel: true)
                }
                continue
            }
            orderedIndexByKey[key] = ordered.count
            ordered.append(SidebarDisplayedDirectory(
                text: displayLabel ?? directory,
                isDisplayLabel: displayLabel != nil
            ))
        }

        if includeFallback, ordered.isEmpty, let fallbackDirectory = presentedCurrentDirectory {
            return [SidebarDisplayedDirectory(text: fallbackDirectory, isDisplayLabel: false)]
        }
        return ordered
    }

    func sidebarDirectoriesInDisplayOrder() -> [String] {
        sidebarDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering()
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: sidebarPanelGitBranches(orderedPanelIds: orderedPanelIds),
                fallbackBranch: presentedGitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarGitBranchesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        return SidebarBranchOrdering().orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: sidebarPanelGitBranches(orderedPanelIds: orderedPanelIds),
            panelDirectories: resolvedDirectories,
            panelDirectoryDisplayLabels: panelDirectoryDisplayLabels,
            defaultDirectory: presentedCurrentDirectory,
            homeDirectoryForTildeExpansion: sidebarHomeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            ),
            fallbackBranch: presentedGitBranch
        )
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    var presentedGitBranch: SidebarGitBranchState? {
        if isRemoteWorkspace, presentedCurrentDirectory == nil { return nil }
        return gitBranch
    }

    func reportedPanelGitBranch(panelId: UUID) -> SidebarGitBranchState? {
        guard let branch = panelGitBranches[panelId] else { return nil }
        if isRemoteWorkspace, reportedPanelDirectory(panelId: panelId) == nil { return nil }
        return branch
    }

    private func sidebarPanelGitBranches(orderedPanelIds: [UUID]) -> [UUID: SidebarGitBranchState] {
        var branches: [UUID: SidebarGitBranchState] = [:]
        for panelId in orderedPanelIds {
            if let branch = reportedPanelGitBranch(panelId: panelId) {
                branches[panelId] = branch
            }
        }
        return branches
    }
}

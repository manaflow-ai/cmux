import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Sidebar metadata and git/PR state
extension Workspace {
    func scheduleExtensionSidebarProjectRootRefresh(for directory: String) {
        extensionSidebarProjectRootRefreshID &+= 1
        let refreshID = extensionSidebarProjectRootRefreshID
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else {
            extensionSidebarProjectRootPath = nil
            return
        }

        Task.detached(priority: .utility) { [weak self, trimmedDirectory, refreshID] in
            let projectRootPath = Self.extensionSidebarProjectRootPath(onDiskFor: trimmedDirectory)
            await MainActor.run { [weak self] in
                guard let self,
                      self.extensionSidebarProjectRootRefreshID == refreshID else {
                    return
                }
                self.extensionSidebarProjectRootPath = projectRootPath
            }
        }
    }

    nonisolated private static func extensionSidebarProjectRootPath(onDiskFor directory: String) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        while url.path != "/" {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
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

    func clearPanelGitBranch(panelId: UUID) {
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

    func updatePanelPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        isStale: Bool = false
    ) {
        let existing = panelPullRequests[panelId]
        let normalizedBranch = normalizedSidebarBranchName(branch)
        let currentPanelBranch = normalizedSidebarBranchName(panelGitBranches[panelId]?.branch)
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

    func clearPanelPullRequest(panelId: UUID) {
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId, pullRequest != nil {
            pullRequest = nil
        }
    }

    func clearSidebarPullRequestMetadata() {
        if !panelPullRequests.isEmpty {
            panelPullRequests.removeAll()
        }
        if pullRequest != nil {
            pullRequest = nil
        }
    }

    func clearSidebarGitMetadata() {
        if !panelGitBranches.isEmpty {
            panelGitBranches.removeAll()
        }
        clearSidebarPullRequestMetadata()
        if gitBranch != nil {
            gitBranch = nil
        }
    }

    func resetSidebarContext(reason: String = "unspecified") {
        statusEntries.removeAll()
        agentPIDs.removeAll()
        agentPIDPanelIdsByKey.removeAll()
        agentPIDKeysByPanelId.removeAll()
        clearAllAgentLifecycleStates()
        agentListeningPorts.removeAll()
        latestConversationMessage = nil
        latestSubmittedMessage = nil
        latestSubmittedAt = nil
        logEntries.removeAll()
        progress = nil
        gitBranch = nil
        panelGitBranches.removeAll()
        pullRequest = nil
        panelPullRequests.removeAll()
        surfaceListeningPorts.removeAll()
        listeningPorts.removeAll()
        metadataBlocks.removeAll()
        resetBrowserPanelsForContextChange(reason: reason)
    }

    private func resetBrowserPanelsForContextChange(reason: String) {
        let browserPanels = panels.values.compactMap { $0 as? BrowserPanel }
        guard !browserPanels.isEmpty else { return }

#if DEBUG
        cmuxDebugLog(
            "workspace.contextReset.browserPanels workspace=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) count=\(browserPanels.count)"
        )
#endif

        for browserPanel in browserPanels {
            browserPanel.resetForWorkspaceContextChange(reason: reason)
            let nextTitle = browserPanel.displayTitle
            _ = updatePanelTitle(panelId: browserPanel.id, title: nextTitle)

            guard let tabId = surfaceIdFromPanelId(browserPanel.id),
                  let existing = bonsplitController.tab(tabId) else {
                continue
            }

            let faviconUpdate: Data?? = existing.iconImageData == nil ? nil : .some(nil)
            let loadingUpdate: Bool? = existing.isLoading ? false : nil

            guard faviconUpdate != nil || loadingUpdate != nil else {
                continue
            }

            bonsplitController.updateTab(
                tabId,
                iconImageData: faviconUpdate,
                hasCustomTitle: panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var didMutate = false
        var didMutatePanelTitle = false
        var didMutateWorkspaceTitle = false

        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
            didMutatePanelTitle = true
        }

        // Update bonsplit tab title only when this panel's title changed.
        if didMutate,
           let tabId = surfaceIdFromPanelId(panelId),
           let panel = panels[panelId] {
            let baseTitle = panelTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
            bonsplitController.updateTab(
                tabId,
                title: resolvedTitle,
                hasCustomTitle: panelCustomTitles[panelId] != nil
            )
        }

        // If this is the only panel and no custom title, update workspace title
        if panels.count == 1, customTitle == nil {
            if self.title != trimmed {
                self.title = trimmed
                didMutate = true
                didMutateWorkspaceTitle = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

#if DEBUG
        if didMutate {
            cmuxDebugLog(
                "workspace.title.updatePanel workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) panels=\(panels.count) custom=\(customTitle == nil ? 0 : 1) " +
                "panelChanged=\(didMutatePanelTitle ? 1 : 0) workspaceChanged=\(didMutateWorkspaceTitle ? 1 : 0) " +
                "title=\"\(debugWorkspaceDescriptionPreview(trimmed, limit: 80))\""
            )
        }
#endif
        return didMutate
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        for panelId in Array(pendingTerminalInputObserversByPanelId.keys) where !validSurfaceIds.contains(panelId) {
            removePendingTerminalInputObservers(forPanelId: panelId)
        }
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        restoredUnreadPanelIndicators = restoredUnreadPanelIndicators.filter { validSurfaceIds.contains($0.key) }
        panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        restoredGuardedWorkingDirectoriesByPanelId = restoredGuardedWorkingDirectoriesByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        remotePTYSessionIDsByPanelId = remotePTYSessionIDsByPanelId.filter { validSurfaceIds.contains($0.key) }
        endedPersistentRemotePTYAttachSurfaceIds = endedPersistentRemotePTYAttachSurfaceIds.filter { validSurfaceIds.contains($0) }
        pruneRemoteRelaySurfaceAliases(validSurfaceIds: validSurfaceIds)
        remoteDetectedSurfaceIds = remoteDetectedSurfaceIds.filter { validSurfaceIds.contains($0) }
        panelShellActivityStates = panelShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        panelPullRequests = panelPullRequests.filter { validSurfaceIds.contains($0.key) }
        let staleAgentPIDPanelIds = agentPIDKeysByPanelId.keys.filter { !validSurfaceIds.contains($0) }
        var didClearStaleAgentRuntime = false
        for panelId in staleAgentPIDPanelIds {
            let keys = agentPIDKeysByPanelId[panelId] ?? []
            for key in keys {
                if clearAgentPID(key: key, panelId: panelId, clearStatus: true, refreshPorts: false) {
                    didClearStaleAgentRuntime = true
                }
            }
        }
        if didClearStaleAgentRuntime {
            refreshTrackedAgentPorts()
        }
        restoredAgentSnapshotsByPanelId = restoredAgentSnapshotsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        surfaceResumeBindingsByPanelId = surfaceResumeBindingsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        restoredAgentResumeStatesByPanelId = restoredAgentResumeStatesByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        invalidatedRestoredAgentFingerprintsByPanelId = invalidatedRestoredAgentFingerprintsByPanelId.filter {
            validSurfaceIds.contains($0.key)
        }
        syncRemotePortScanTTYs()
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
            .union(remoteDetectedPorts)
            .union(remoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }

    func sidebarOrderedPanelIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { panelIdFromSurfaceId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return SidebarBranchOrdering.orderedPanelIds(
            tree: tree,
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    private func normalizedSidebarDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sidebarHomeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        if isRemoteWorkspace {
            return SidebarBranchOrdering.inferredRemoteHomeDirectory(
                from: Array(resolvedPanelDirectories.values),
                fallbackDirectory: normalizedSidebarDirectory(currentDirectory)
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func sidebarResolvedDirectory(for panelId: UUID) -> String? {
        if let directory = normalizedSidebarDirectory(panelDirectories[panelId]) {
            return directory
        }
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

    func sidebarDirectoriesInDisplayOrder(orderedPanelIds: [UUID], includeFallback: Bool = true) -> [String] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        let homeDirectoryForCanonicalization = sidebarHomeDirectoryForCanonicalization(
            resolvedPanelDirectories: resolvedDirectories
        )
        var ordered: [String] = []
        var seen: Set<String> = []

        for panelId in orderedPanelIds {
            guard let directory = resolvedDirectories[panelId],
                  let key = SidebarBranchOrdering.canonicalDirectoryKey(
                      directory,
                      homeDirectoryForTildeExpansion: homeDirectoryForCanonicalization
                  ) else { continue }
            if seen.insert(key).inserted {
                ordered.append(directory)
            }
        }

        if includeFallback, ordered.isEmpty, let fallbackDirectory = normalizedSidebarDirectory(currentDirectory) {
            return [fallbackDirectory]
        }

        return ordered
    }

    func sidebarDirectoriesInDisplayOrder() -> [String] {
        sidebarDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }
    func sidebarFinderDirectory() -> String? {
        guard !isRemoteWorkspace else { return nil }
        let panelIds = sidebarOrderedPanelIds()
        let localPanelIds = panelIds.filter {
            !remoteDetectedSurfaceIds.contains($0)
                && !isRemoteTerminalSurface($0)
                && !pendingRemoteTerminalChildExitSurfaceIds.contains($0)
        }
        return sidebarDirectoriesInDisplayOrder(orderedPanelIds: localPanelIds, includeFallback: panelIds.isEmpty || localPanelIds.count == panelIds.count).first
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
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
        return SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: panelGitBranches,
            panelDirectories: resolvedDirectories,
            defaultDirectory: normalizedSidebarDirectory(currentDirectory),
            homeDirectoryForTildeExpansion: sidebarHomeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            ),
            fallbackBranch: gitBranch
        )
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        let validPanelPullRequests = panelPullRequests.filter { panelId, state in
            guard let pullRequestBranch = normalizedSidebarBranchName(state.branch) else {
                return true
            }
            return normalizedSidebarBranchName(panelGitBranches[panelId]?.branch) == pullRequestBranch
        }
        return SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            panelPullRequests: validPanelPullRequests,
            fallbackPullRequest: nil
        )
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        sidebarStatusEntriesVisibleForDisplay().sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        metadataBlocks.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    @discardableResult
    func recordConversationMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        guard latestConversationMessage != preview else { return false }
        latestConversationMessage = preview
        return true
    }

    @discardableResult
    func recordSubmittedMessage(_ message: String?) -> Bool {
        guard let preview = Self.conversationMessagePreview(from: message) else { return false }
        _ = recordConversationMessage(preview)
        latestSubmittedMessage = preview
        latestSubmittedAt = Date()
        return true
    }

    func appendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logEntries.append(SidebarLogEntry(message: trimmed, level: level, source: source, timestamp: Date()))
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if logEntries.count > limit {
            logEntries.removeFirst(logEntries.count - limit)
        }
    }

    // MARK: - Panel Operations

}

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CoreText

func cmuxSurfaceContextName(_ context: ghostty_surface_context_e) -> String {
    switch context {
    case GHOSTTY_SURFACE_CONTEXT_WINDOW:
        return "window"
    case GHOSTTY_SURFACE_CONTEXT_TAB:
        return "tab"
    case GHOSTTY_SURFACE_CONTEXT_SPLIT:
        return "split"
    default:
        return "unknown(\(context))"
    }
}

func cmuxCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    guard let quicklookFont = ghostty_surface_quicklook_font(surface) else {
        return nil
    }

    let ctFont = Unmanaged<CTFont>.fromOpaque(quicklookFont).takeRetainedValue()
    let points = Float(CTFontGetSize(ctFont))
    guard points > 0 else { return nil }
    return points
}

func cmuxInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> ghostty_surface_config_s {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    var config = inherited

    // Make runtime zoom inheritance explicit, even when Ghostty's
    // inherit-font-size config is disabled.
    let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.font_size = points
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.font_size)
    dlog(
        "zoom.inherit context=\(cmuxSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}

struct SidebarStatusEntry {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let timestamp: Date
}

private struct SessionPaneRestoreEntry {
    let paneId: PaneID
    let snapshot: SessionPaneLayoutSnapshot
}

extension Workspace {
    func sessionSnapshot(includeScrollback: Bool) -> SessionWorkspaceSnapshot {
        let tree = bonsplitController.treeSnapshot()
        let layout = sessionLayoutSnapshot(from: tree)

        let orderedPanelIds = sidebarOrderedPanelIds()
        var seen: Set<UUID> = []
        var allPanelIds: [UUID] = []
        for panelId in orderedPanelIds where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }

        let panelSnapshots = allPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { sessionPanelSnapshot(panelId: $0, includeScrollback: includeScrollback) }

        let statusSnapshots = statusEntries.values
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { entry in
                SessionStatusEntrySnapshot(
                    key: entry.key,
                    value: entry.value,
                    icon: entry.icon,
                    color: entry.color,
                    timestamp: entry.timestamp.timeIntervalSince1970
                )
            }
        let logSnapshots = logEntries.map { entry in
            SessionLogEntrySnapshot(
                message: entry.message,
                level: entry.level.rawValue,
                source: entry.source,
                timestamp: entry.timestamp.timeIntervalSince1970
            )
        }

        let progressSnapshot = progress.map { progress in
            SessionProgressSnapshot(value: progress.value, label: progress.label)
        }
        let gitBranchSnapshot = gitBranch.map { branch in
            SessionGitBranchSnapshot(branch: branch.branch, isDirty: branch.isDirty)
        }

        return SessionWorkspaceSnapshot(
            processTitle: processTitle,
            customTitle: customTitle,
            customColor: customColor,
            isPinned: isPinned,
            currentDirectory: currentDirectory,
            focusedPanelId: focusedPanelId,
            layout: layout,
            panels: panelSnapshots,
            statusEntries: statusSnapshots,
            logEntries: logSnapshots,
            progress: progressSnapshot,
            gitBranch: gitBranchSnapshot
        )
    }

    func restoreSessionSnapshot(_ snapshot: SessionWorkspaceSnapshot) {
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)

        let normalizedCurrentDirectory = snapshot.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCurrentDirectory.isEmpty {
            currentDirectory = normalizedCurrentDirectory
        }

        let panelSnapshotsById = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        let leafEntries = restoreSessionLayout(snapshot.layout)
        var oldToNewPanelIds: [UUID: UUID] = [:]

        for entry in leafEntries {
            restorePane(
                entry.paneId,
                snapshot: entry.snapshot,
                panelSnapshotsById: panelSnapshotsById,
                oldToNewPanelIds: &oldToNewPanelIds
            )
        }

        pruneSurfaceMetadata(validSurfaceIds: Set(panels.keys))
        applySessionDividerPositions(snapshotNode: snapshot.layout, liveNode: bonsplitController.treeSnapshot())

        applyProcessTitle(snapshot.processTitle)
        setCustomTitle(snapshot.customTitle)
        setCustomColor(snapshot.customColor)
        isPinned = snapshot.isPinned

        statusEntries = Dictionary(
            uniqueKeysWithValues: snapshot.statusEntries.map { entry in
                (
                    entry.key,
                    SidebarStatusEntry(
                        key: entry.key,
                        value: entry.value,
                        icon: entry.icon,
                        color: entry.color,
                        timestamp: Date(timeIntervalSince1970: entry.timestamp)
                    )
                )
            }
        )
        logEntries = snapshot.logEntries.map { entry in
            SidebarLogEntry(
                message: entry.message,
                level: SidebarLogLevel(rawValue: entry.level) ?? .info,
                source: entry.source,
                timestamp: Date(timeIntervalSince1970: entry.timestamp)
            )
        }
        progress = snapshot.progress.map { SidebarProgressState(value: $0.value, label: $0.label) }
        gitBranch = snapshot.gitBranch.map { SidebarGitBranchState(branch: $0.branch, isDirty: $0.isDirty) }

        recomputeListeningPorts()

        if let focusedOldPanelId = snapshot.focusedPanelId,
           let focusedNewPanelId = oldToNewPanelIds[focusedOldPanelId],
           panels[focusedNewPanelId] != nil {
            focusPanel(focusedNewPanelId)
        } else if let fallbackFocusedPanelId = focusedPanelId, panels[fallbackFocusedPanelId] != nil {
            focusPanel(fallbackFocusedPanelId)
        } else {
            scheduleFocusReconcile()
        }
    }

    private func sessionLayoutSnapshot(from node: ExternalTreeNode) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .pane(let pane):
            let panelIds = sessionPanelIDs(for: pane)
            let selectedPanelId = pane.selectedTabId.flatMap(sessionPanelID(forExternalTabIDString:))
            return .pane(
                SessionPaneLayoutSnapshot(
                    panelIds: panelIds,
                    selectedPanelId: selectedPanelId
                )
            )
        case .split(let split):
            return .split(
                SessionSplitLayoutSnapshot(
                    orientation: split.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    dividerPosition: split.dividerPosition,
                    first: sessionLayoutSnapshot(from: split.first),
                    second: sessionLayoutSnapshot(from: split.second)
                )
            )
        }
    }

    private func sessionPanelIDs(for pane: ExternalPaneNode) -> [UUID] {
        var panelIds: [UUID] = []
        var seen = Set<UUID>()
        for tab in pane.tabs {
            guard let panelId = sessionPanelID(forExternalTabIDString: tab.id) else { continue }
            if seen.insert(panelId).inserted {
                panelIds.append(panelId)
            }
        }
        return panelIds
    }

    private func sessionPanelID(forExternalTabIDString tabIDString: String) -> UUID? {
        guard let tabUUID = UUID(uuidString: tabIDString) else { return nil }
        for (surfaceId, panelId) in surfaceIdToPanelId {
            guard let surfaceUUID = sessionSurfaceUUID(for: surfaceId) else { continue }
            if surfaceUUID == tabUUID {
                return panelId
            }
        }
        return nil
    }

    private func sessionSurfaceUUID(for surfaceId: TabID) -> UUID? {
        struct EncodedSurfaceID: Decodable {
            let id: UUID
        }

        guard let data = try? JSONEncoder().encode(surfaceId),
              let decoded = try? JSONDecoder().decode(EncodedSurfaceID.self, from: data) else {
            return nil
        }
        return decoded.id
    }

    private func sessionPanelSnapshot(panelId: UUID, includeScrollback: Bool) -> SessionPanelSnapshot? {
        guard let panel = panels[panelId] else { return nil }

        let panelTitle = panelTitle(panelId: panelId)
        let customTitle = panelCustomTitles[panelId]
        let directory = panelDirectories[panelId]
        let isPinned = pinnedPanelIds.contains(panelId)
        let isManuallyUnread = manualUnreadPanelIds.contains(panelId)
        let branchSnapshot = panelGitBranches[panelId].map {
            SessionGitBranchSnapshot(branch: $0.branch, isDirty: $0.isDirty)
        }
        let listeningPorts = (surfaceListeningPorts[panelId] ?? []).sorted()
        let ttyName = surfaceTTYNames[panelId]

        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminalPanel = panel as? TerminalPanel else { return nil }
            let capturedScrollback = includeScrollback
                ? TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminalPanel,
                    includeScrollback: true,
                    lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                )
                : nil
            let resolvedScrollback = terminalSnapshotScrollback(
                panelId: panelId,
                capturedScrollback: capturedScrollback,
                includeScrollback: includeScrollback
            )
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: panelDirectories[panelId],
                scrollback: resolvedScrollback
            )
            browserSnapshot = nil
        case .browser:
            guard let browserPanel = panel as? BrowserPanel else { return nil }
            terminalSnapshot = nil
            let historySnapshot = browserPanel.sessionNavigationHistorySnapshot()
            browserSnapshot = SessionBrowserPanelSnapshot(
                urlString: browserPanel.preferredURLStringForOmnibar(),
                shouldRenderWebView: browserPanel.shouldRenderWebView,
                pageZoom: Double(browserPanel.webView.pageZoom),
                developerToolsVisible: browserPanel.isDeveloperToolsVisible(),
                backHistoryURLStrings: historySnapshot.backHistoryURLStrings,
                forwardHistoryURLStrings: historySnapshot.forwardHistoryURLStrings
            )
        }

        return SessionPanelSnapshot(
            id: panelId,
            type: panel.panelType,
            title: panelTitle,
            customTitle: customTitle,
            directory: directory,
            isPinned: isPinned,
            isManuallyUnread: isManuallyUnread,
            gitBranch: branchSnapshot,
            listeningPorts: listeningPorts,
            ttyName: ttyName,
            terminal: terminalSnapshot,
            browser: browserSnapshot
        )
    }

    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?
    ) -> String? {
        if let captured = SessionPersistencePolicy.truncatedScrollback(capturedScrollback) {
            return captured
        }
        return SessionPersistencePolicy.truncatedScrollback(fallbackScrollback)
    }

    private func terminalSnapshotScrollback(
        panelId: UUID,
        capturedScrollback: String?,
        includeScrollback: Bool
    ) -> String? {
        guard includeScrollback else { return nil }
        let fallback = restoredTerminalScrollbackByPanelId[panelId]
        let resolved = Self.resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallback
        )
        if let resolved {
            restoredTerminalScrollbackByPanelId[panelId] = resolved
        } else {
            restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        }
        return resolved
    }

    private func restoreSessionLayout(_ layout: SessionWorkspaceLayoutSnapshot) -> [SessionPaneRestoreEntry] {
        guard let rootPaneId = bonsplitController.allPaneIds.first else {
            return []
        }

        var leaves: [SessionPaneRestoreEntry] = []
        restoreSessionLayoutNode(layout, inPane: rootPaneId, leaves: &leaves)
        return leaves
    }

    private func restoreSessionLayoutNode(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane paneId: PaneID,
        leaves: inout [SessionPaneRestoreEntry]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append(SessionPaneRestoreEntry(paneId: paneId, snapshot: pane))
        case .split(let split):
            var anchorPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { panelIdFromSurfaceId($0.id) }
                .first

            if anchorPanelId == nil {
                anchorPanelId = newTerminalSurface(inPane: paneId, focus: false)?.id
            }

            guard let anchorPanelId,
                  let newSplitPanel = newTerminalSplit(
                    from: anchorPanelId,
                    orientation: split.orientation.splitOrientation,
                    insertFirst: false,
                    focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append(
                    SessionPaneRestoreEntry(
                        paneId: paneId,
                        snapshot: SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
                    )
                )
                return
            }

            restoreSessionLayoutNode(split.first, inPane: paneId, leaves: &leaves)
            restoreSessionLayoutNode(split.second, inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func restorePane(
        _ paneId: PaneID,
        snapshot: SessionPaneLayoutSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot],
        oldToNewPanelIds: inout [UUID: UUID]
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }
        let desiredOldPanelIds = snapshot.panelIds.filter { panelSnapshotsById[$0] != nil }

        var createdPanelIds: [UUID] = []
        for oldPanelId in desiredOldPanelIds {
            guard let panelSnapshot = panelSnapshotsById[oldPanelId] else { continue }
            guard let createdPanelId = createPanel(from: panelSnapshot, inPane: paneId) else { continue }
            createdPanelIds.append(createdPanelId)
            oldToNewPanelIds[oldPanelId] = createdPanelId
        }

        guard !createdPanelIds.isEmpty else { return }

        for oldPanelId in existingPanelIds where !createdPanelIds.contains(oldPanelId) {
            _ = closePanel(oldPanelId, force: true)
        }

        for (index, panelId) in createdPanelIds.enumerated() {
            _ = reorderSurface(panelId: panelId, toIndex: index)
        }

        let selectedPanelId: UUID? = {
            if let selectedOldId = snapshot.selectedPanelId {
                return oldToNewPanelIds[selectedOldId]
            }
            return createdPanelIds.first
        }()

        if let selectedPanelId,
           let selectedTabId = surfaceIdFromPanelId(selectedPanelId) {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(selectedTabId)
        }
    }

    private func createPanel(from snapshot: SessionPanelSnapshot, inPane paneId: PaneID) -> UUID? {
        switch snapshot.type {
        case .terminal:
            let workingDirectory = snapshot.terminal?.workingDirectory ?? snapshot.directory ?? currentDirectory
            let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(
                for: snapshot.terminal?.scrollback
            )
            guard let terminalPanel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: workingDirectory,
                startupEnvironment: replayEnvironment
            ) else {
                return nil
            }
            let fallbackScrollback = SessionPersistencePolicy.truncatedScrollback(snapshot.terminal?.scrollback)
            if let fallbackScrollback {
                restoredTerminalScrollbackByPanelId[terminalPanel.id] = fallbackScrollback
            } else {
                restoredTerminalScrollbackByPanelId.removeValue(forKey: terminalPanel.id)
            }
            applySessionPanelMetadata(snapshot, toPanelId: terminalPanel.id)
            return terminalPanel.id
        case .browser:
            let initialURL = snapshot.browser?.urlString.flatMap { URL(string: $0) }
            guard let browserPanel = newBrowserSurface(
                inPane: paneId,
                url: initialURL,
                focus: false
            ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: browserPanel.id)
            return browserPanel.id
        }
    }

    private func applySessionPanelMetadata(_ snapshot: SessionPanelSnapshot, toPanelId panelId: UUID) {
        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            panelTitles[panelId] = title
        }

        setPanelCustomTitle(panelId: panelId, title: snapshot.customTitle)
        setPanelPinned(panelId: panelId, pinned: snapshot.isPinned)

        if snapshot.isManuallyUnread {
            markPanelUnread(panelId)
        } else {
            clearManualUnread(panelId: panelId)
        }

        if let directory = snapshot.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            updatePanelDirectory(panelId: panelId, directory: directory)
        }

        if let branch = snapshot.gitBranch {
            panelGitBranches[panelId] = SidebarGitBranchState(branch: branch.branch, isDirty: branch.isDirty)
        } else {
            panelGitBranches.removeValue(forKey: panelId)
        }

        surfaceListeningPorts[panelId] = Array(Set(snapshot.listeningPorts)).sorted()

        if let ttyName = snapshot.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            surfaceTTYNames[panelId] = ttyName
        } else {
            surfaceTTYNames.removeValue(forKey: panelId)
        }

        if let browserSnapshot = snapshot.browser,
           let browserPanel = browserPanel(for: panelId) {
            browserPanel.restoreSessionNavigationHistory(
                backHistoryURLStrings: browserSnapshot.backHistoryURLStrings ?? [],
                forwardHistoryURLStrings: browserSnapshot.forwardHistoryURLStrings ?? [],
                currentURLString: browserSnapshot.urlString
            )

            let pageZoom = CGFloat(max(0.25, min(5.0, browserSnapshot.pageZoom)))
            if pageZoom.isFinite {
                browserPanel.webView.pageZoom = pageZoom
            }

            if browserSnapshot.developerToolsVisible {
                _ = browserPanel.showDeveloperTools()
                browserPanel.requestDeveloperToolsRefreshAfterNextAttach(reason: "session_restore")
            } else {
                _ = browserPanel.hideDeveloperTools()
            }
        }
    }

    private func applySessionDividerPositions(
        snapshotNode: SessionWorkspaceLayoutSnapshot,
        liveNode: ExternalTreeNode
    ) {
        switch (snapshotNode, liveNode) {
        case (.split(let snapshotSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(snapshotSplit.dividerPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            applySessionDividerPositions(snapshotNode: snapshotSplit.first, liveNode: liveSplit.first)
            applySessionDividerPositions(snapshotNode: snapshotSplit.second, liveNode: liveSplit.second)
        default:
            return
        }
    }
}

enum SidebarLogLevel: String {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState {
    let value: Double
    let label: String?
}

struct SidebarGitBranchState {
    let branch: String
    let isDirty: Bool
}

enum SidebarBranchOrdering {
    struct BranchEntry: Equatable {
        let name: String
        let isDirty: Bool
    }

    struct BranchDirectoryEntry: Equatable {
        let branch: String?
        let isDirty: Bool
        let directory: String?
    }

    static func orderedPaneIds(tree: ExternalTreeNode) -> [String] {
        switch tree {
        case .pane(let pane):
            return [pane.id]
        case .split(let split):
            // Bonsplit split order matches visual order for both horizontal and vertical splits.
            return orderedPaneIds(tree: split.first) + orderedPaneIds(tree: split.second)
        }
    }

    static func orderedPanelIds(
        tree: ExternalTreeNode,
        paneTabs: [String: [UUID]],
        fallbackPanelIds: [UUID]
    ) -> [UUID] {
        var ordered: [UUID] = []
        var seen: Set<UUID> = []

        for paneId in orderedPaneIds(tree: tree) {
            for panelId in paneTabs[paneId] ?? [] {
                if seen.insert(panelId).inserted {
                    ordered.append(panelId)
                }
            }
        }

        for panelId in fallbackPanelIds {
            if seen.insert(panelId).inserted {
                ordered.append(panelId)
            }
        }

        return ordered
    }

    static func orderedUniqueBranches(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchEntry] {
        var orderedNames: [String] = []
        var branchDirty: [String: Bool] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelBranches[panelId] else { continue }
            let name = state.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            if branchDirty[name] == nil {
                orderedNames.append(name)
                branchDirty[name] = state.isDirty
            } else if state.isDirty {
                branchDirty[name] = true
            }
        }

        if orderedNames.isEmpty, let fallbackBranch {
            let name = fallbackBranch.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return [BranchEntry(name: name, isDirty: fallbackBranch.isDirty)]
            }
        }

        return orderedNames.map { name in
            BranchEntry(name: name, isDirty: branchDirty[name] ?? false)
        }
    }

    static func orderedUniqueBranchDirectoryEntries(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        panelDirectories: [UUID: String],
        defaultDirectory: String?,
        fallbackBranch: SidebarGitBranchState?
    ) -> [BranchDirectoryEntry] {
        struct EntryKey: Hashable {
            let directory: String?
            let branch: String?
        }

        struct MutableEntry {
            var branch: String?
            var isDirty: Bool
            var directory: String?
        }

        func normalized(_ text: String?) -> String? {
            guard let text else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func canonicalDirectoryKey(_ directory: String?) -> String? {
            guard let directory = normalized(directory) else { return nil }
            let expanded = NSString(string: directory).expandingTildeInPath
            let standardized = NSString(string: expanded).standardizingPath
            let cleaned = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        let normalizedFallbackBranch = normalized(fallbackBranch?.branch)
        let shouldUseFallbackBranchPerPanel = !orderedPanelIds.contains {
            normalized(panelBranches[$0]?.branch) != nil
        }
        let defaultBranchForPanels = shouldUseFallbackBranchPerPanel ? normalizedFallbackBranch : nil
        let defaultBranchDirty = shouldUseFallbackBranchPerPanel ? (fallbackBranch?.isDirty ?? false) : false

        var order: [EntryKey] = []
        var entries: [EntryKey: MutableEntry] = [:]

        for panelId in orderedPanelIds {
            let panelBranch = normalized(panelBranches[panelId]?.branch)
            let branch = panelBranch ?? defaultBranchForPanels
            let directory = normalized(panelDirectories[panelId] ?? defaultDirectory)
            guard branch != nil || directory != nil else { continue }

            let panelDirty = panelBranch != nil
                ? (panelBranches[panelId]?.isDirty ?? false)
                : defaultBranchDirty

            let key: EntryKey
            if let directoryKey = canonicalDirectoryKey(directory) {
                // Keep one line per directory and allow the latest branch state to overwrite.
                key = EntryKey(directory: directoryKey, branch: nil)
            } else {
                key = EntryKey(directory: nil, branch: branch)
            }

            guard key.directory != nil || key.branch != nil else { continue }

            if var existing = entries[key] {
                if key.directory != nil {
                    if let branch {
                        existing.branch = branch
                        existing.isDirty = panelDirty
                    } else if existing.branch == nil {
                        existing.isDirty = panelDirty
                    }
                    if let directory {
                        existing.directory = directory
                    }
                    entries[key] = existing
                } else if panelDirty {
                    existing.isDirty = true
                    entries[key] = existing
                }
            } else {
                order.append(key)
                entries[key] = MutableEntry(branch: branch, isDirty: panelDirty, directory: directory)
            }
        }

        if order.isEmpty {
            let fallbackDirectory = normalized(defaultDirectory)
            if normalizedFallbackBranch != nil || fallbackDirectory != nil {
                return [
                    BranchDirectoryEntry(
                        branch: normalizedFallbackBranch,
                        isDirty: fallbackBranch?.isDirty ?? false,
                        directory: fallbackDirectory
                    )
                ]
            }
        }

        return order.compactMap { key in
            guard let entry = entries[key] else { return nil }
            return BranchDirectoryEntry(
                branch: entry.branch,
                isDirty: entry.isDirty,
                directory: entry.directory
            )
        }
    }
}

struct ClosedBrowserPanelRestoreSnapshot {
    let workspaceId: UUID
    let url: URL?
    let originalPaneId: UUID
    let originalTabIndex: Int
    let fallbackSplitOrientation: SplitOrientation?
    let fallbackSplitInsertFirst: Bool
    let fallbackAnchorPaneId: UUID?
}

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var isPinned: Bool = false
    @Published var customColor: String?  // hex string, e.g. "#C0392B"
    @Published var currentDirectory: String

    /// Ordinal for CMUX_PORT range assignment (monotonically increasing per app session)
    var portOrdinal: Int = 0

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// Mapping from bonsplit TabID to our Panel instances
    @Published private(set) var panels: [UUID: any Panel] = [:]

    /// Subscriptions for panel updates (e.g., browser title changes)
    private var panelSubscriptions: [UUID: AnyCancellable] = [:]

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels)
    private var isProgrammaticSplit = false

    /// Last terminal panel used as an inheritance source (typically last focused terminal).
    private var lastTerminalConfigInheritancePanelId: UUID?
    /// Last known terminal font points from inheritance sources. Used as fallback when
    /// no live terminal surface is currently available.
    private var lastTerminalConfigInheritanceFontPoints: Float?
    /// Per-panel inherited zoom lineage. Descendants reuse this root value unless
    /// a panel is explicitly re-zoomed by the user.
    private var terminalInheritanceFontPointsByPanelId: [UUID: Float] = [:]

    /// Callback used by TabManager to capture recently closed browser panels for Cmd+Shift+T restore.
    var onClosedBrowserPanel: ((ClosedBrowserPanelRestoreSnapshot) -> Void)?


    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// The currently focused pane's panel ID
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return panelIdFromSurfaceId(tab.id)
    }

    /// The currently focused terminal panel (if any)
    var focusedTerminalPanel: TerminalPanel? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalPanel else {
            return nil
        }
        return panel
    }

    enum FocusPanelTrigger {
        case standard
        case terminalFirstResponder
    }

    /// Published directory for each panel
    @Published var panelDirectories: [UUID: String] = [:]
    @Published var panelTitles: [UUID: String] = [:]
    @Published private(set) var panelCustomTitles: [UUID: String] = [:]
    @Published private(set) var pinnedPanelIds: Set<UUID> = []
    @Published private(set) var manualUnreadPanelIds: Set<UUID> = []
    private var manualUnreadMarkedAt: [UUID: Date] = [:]
    nonisolated private static let manualUnreadFocusGraceInterval: TimeInterval = 0.2
    nonisolated private static let manualUnreadClearDelayAfterFocusFlash: TimeInterval = 0.2
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var logEntries: [SidebarLogEntry] = []
    @Published var progress: SidebarProgressState?
    @Published var gitBranch: SidebarGitBranchState?
    @Published var panelGitBranches: [UUID: SidebarGitBranchState] = [:]
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    @Published var listeningPorts: [Int] = []
    var surfaceTTYNames: [UUID: String] = [:]
    private var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]

    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    private var processTitle: String

    private enum SurfaceKind {
        static let terminal = "terminal"
        static let browser = "browser"
    }

    // MARK: - Initialization

    private static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip("New Terminal"),
            newBrowser: KeyboardShortcutSettings.Action.openBrowser.tooltip("New Browser"),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip("Split Right"),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip("Split Down")
        )
    }

    private static func bonsplitAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        bonsplitAppearance(from: config.backgroundColor)
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        .init(backgroundHex: backgroundColor.hexString())
    }

    private static func bonsplitAppearance(from backgroundColor: NSColor) -> BonsplitConfiguration.Appearance {
        let chromeColors = resolvedChromeColors(from: backgroundColor)
        return BonsplitConfiguration.Appearance(
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: chromeColors
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        applyGhosttyChrome(backgroundColor: config.backgroundColor, reason: reason)
    }

    func applyGhosttyChrome(backgroundColor: NSColor, reason: String = "unspecified") {
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let nextChromeColors = Self.resolvedChromeColors(from: backgroundColor)
        let isNoOp = currentChromeColors.backgroundHex == nextChromeColors.backgroundHex &&
            currentChromeColors.borderHex == nextChromeColors.borderHex

        if GhosttyApp.shared.backgroundLogEnabled {
            let currentBackgroundHex = currentChromeColors.backgroundHex ?? "nil"
            let nextBackgroundHex = nextChromeColors.backgroundHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) currentBg=\(currentBackgroundHex) nextBg=\(nextBackgroundHex) currentBorder=\(currentChromeColors.borderHex ?? "nil") nextBorder=\(nextChromeColors.borderHex ?? "nil") noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }
        bonsplitController.configuration.appearance.chromeColors = nextChromeColors
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) resultingBg=\(bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil") resultingBorder=\(bonsplitController.configuration.appearance.chromeColors.borderHex ?? "nil")"
            )
        }
    }

    init(
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: ghostty_surface_config_s? = nil
    ) {
        self.id = UUID()
        self.portOrdinal = portOrdinal
        self.processTitle = title
        self.title = title
        self.customTitle = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // and keep split entry instantaneous.
        // Avoid re-reading/parsing Ghostty config on every new workspace; this hot path
        // runs for socket/CLI workspace creation and can cause visible typing lag.
        let appearance = Self.bonsplitAppearance(from: GhosttyApp.shared.defaultBackgroundColor)
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // Create initial terminal panel
        let terminalPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: configTemplate,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
            portOrdinal: portOrdinal
        )
        panels[terminalPanel.id] = terminalPanel
        panelTitles[terminalPanel.id] = terminalPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: terminalPanel.id, configTemplate: configTemplate)

        // Create initial tab in bonsplit and store the mapping
        var initialTabId: TabID?
        if let tabId = bonsplitController.createTab(
            title: title,
            icon: "terminal.fill",
            kind: SurfaceKind.terminal,
            isDirty: false,
            isPinned: false
        ) {
            surfaceIdToPanelId[tabId] = terminalPanel.id
            initialTabId = tabId
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        bonsplitController.onExternalTabDrop = { [weak self] request in
            self?.handleExternalTabDrop(request) ?? false
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialTabId {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialTabId)
        }
    }

    func refreshSplitButtonTooltips() {
        let tooltips = Self.currentSplitButtonTooltips()
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtonTooltips != tooltips else { return }
        configuration.appearance.splitButtonTooltips = tooltips
        bonsplitController.configuration = configuration
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    private var surfaceIdToPanelId: [TabID: UUID] = [:]

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (e.g., Cmd+W "Close Tab?") so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    private var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    private var pendingCloseConfirmTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    /// Keyed by the closing tab ID, value is the tab ID we want to select next.
    private var postCloseSelectTabId: [TabID: TabID] = [:]
    /// Panel IDs that were in a pane when a pane-close operation was approved.
    /// Bonsplit pane-close does not emit per-tab didClose callbacks.
    private var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]
    private var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]
    private var isApplyingTabSelection = false
    private var pendingTabSelection: (tabId: TabID, pane: PaneID)?
    private var isReconcilingFocusState = false
    private var focusReconcileScheduled = false
#if DEBUG
    private(set) var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    private var debugLastDidMoveTabTimestamp: TimeInterval = 0
    private var debugDidMoveTabEventCount: UInt64 = 0
#endif
    private var geometryReconcileScheduled = false
    private var geometryReconcileNeedsRerun = false
    private var isNormalizingPinnedTabOrder = false
    private var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?
    private var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    private struct PendingNonFocusSplitFocusReassert {
        let generation: UInt64
        let preferredPanelId: UUID
        let splitPanelId: UUID
    }

    struct DetachedSurfaceTransfer {
        let panelId: UUID
        let panel: any Panel
        let title: String
        let icon: String?
        let iconImageData: Data?
        let kind: String?
        let isLoading: Bool
        let isPinned: Bool
        let directory: String?
        let cachedTitle: String?
        let customTitle: String?
        let manuallyUnread: Bool
    }

    private var detachingTabIds: Set<TabID> = []
    private var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] = [:]
    private var activeDetachCloseTransactions: Int = 0
    private var isDetachingCloseTransaction: Bool { activeDetachCloseTransactions > 0 }

#if DEBUG
    private func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
    }


    private func installBrowserPanelSubscription(_ browserPanel: BrowserPanel) {
        let subscription = Publishers.CombineLatest3(
            browserPanel.$pageTitle.removeDuplicates(),
            browserPanel.$isLoading.removeDuplicates(),
            browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] _, isLoading, favicon in
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            let nextTitle = browserPanel.displayTitle
            if self.panelTitles[browserPanel.id] != nextTitle {
                self.panelTitles[browserPanel.id] = nextTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: browserPanel.id, fallback: nextTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading

            guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconImageData: faviconUpdate,
                hasCustomTitle: self.panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
        panelSubscriptions[browserPanel.id] = subscription
    }
    // MARK: - Panel Access

    func panel(for surfaceId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromSurfaceId(surfaceId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalPanel? {
        panels[panelId] as? TerminalPanel
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        panels[panelId] as? BrowserPanel
    }

    private func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal
        case .browser:
            return SurfaceKind.browser
        }
    }

    private func resolvedPanelTitle(panelId: UUID, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedFallback.isEmpty ? "Tab" : trimmedFallback
        if let custom = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return fallbackTitle
    }

    private func syncPinnedStateForTab(_ tabId: TabID, panelId: UUID) {
        let isPinned = pinnedPanelIds.contains(panelId)
        if let panel = panels[panelId] {
            bonsplitController.updateTab(
                tabId,
                kind: .some(surfaceKind(for: panel)),
                isPinned: isPinned
            )
        } else {
            bonsplitController.updateTab(tabId, isPinned: isPinned)
        }
    }

    private func hasUnreadNotification(panelId: UUID) -> Bool {
        AppDelegate.shared?.notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: panelId) ?? false
    }

    private func syncUnreadBadgeStateForPanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let shouldShowUnread = Self.shouldShowUnreadIndicator(
            hasUnreadNotification: hasUnreadNotification(panelId: panelId),
            isManuallyUnread: manualUnreadPanelIds.contains(panelId)
        )
        if let existing = bonsplitController.tab(tabId), existing.showsNotificationBadge == shouldShowUnread {
            return
        }
        bonsplitController.updateTab(tabId, showsNotificationBadge: shouldShowUnread)
    }

    private func normalizePinnedTabs(in paneId: PaneID) {
        guard !isNormalizingPinnedTabOrder else { return }
        isNormalizingPinnedTabOrder = true
        defer { isNormalizingPinnedTabOrder = false }

        let tabs = bonsplitController.tabs(inPane: paneId)
        let pinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
            return pinnedPanelIds.contains(panelId)
        }
        let unpinnedTabs = tabs.filter { tab in
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return true }
            return !pinnedPanelIds.contains(panelId)
        }
        let desiredOrder = pinnedTabs + unpinnedTabs

        for (index, desiredTab) in desiredOrder.enumerated() {
            let currentTabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = currentTabs.firstIndex(where: { $0.id == desiredTab.id }) else { continue }
            if currentIndex != index {
                _ = bonsplitController.reorderTab(desiredTab.id, toIndex: index)
            }
        }
    }

    private func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = panelIdFromSurfaceId(tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }

    func setPanelCustomTitle(panelId: UUID, title: String?) {
        guard panels[panelId] != nil else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if trimmed.isEmpty {
            guard previous != nil else { return }
            panelCustomTitles.removeValue(forKey: panelId)
        } else {
            guard previous != trimmed else { return }
            panelCustomTitles[panelId] = trimmed
        }

        guard let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) else { return }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
    }

    func isPanelPinned(_ panelId: UUID) -> Bool {
        pinnedPanelIds.contains(panelId)
    }

    func panelKind(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        return surfaceKind(for: panel)
    }

    func panelTitle(panelId: UUID) -> String? {
        guard let panel = panels[panelId] else { return nil }
        let fallback = panelTitles[panelId] ?? panel.displayTitle
        return resolvedPanelTitle(panelId: panelId, fallback: fallback)
    }

    func setPanelPinned(panelId: UUID, pinned: Bool) {
        guard panels[panelId] != nil else { return }
        let wasPinned = pinnedPanelIds.contains(panelId)
        guard wasPinned != pinned else { return }
        if pinned {
            pinnedPanelIds.insert(panelId)
        } else {
            pinnedPanelIds.remove(panelId)
        }

        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        normalizePinnedTabs(in: paneId)
    }

    func markPanelUnread(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        guard manualUnreadPanelIds.insert(panelId).inserted else { return }
        manualUnreadMarkedAt[panelId] = Date()
        syncUnreadBadgeStateForPanel(panelId)
    }

    func markPanelRead(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        AppDelegate.shared?.notificationStore?.markRead(forTabId: id, surfaceId: panelId)
        clearManualUnread(panelId: panelId)
    }

    func clearManualUnread(panelId: UUID) {
        let didRemoveUnread = manualUnreadPanelIds.remove(panelId) != nil
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        guard didRemoveUnread else { return }
        syncUnreadBadgeStateForPanel(panelId)
    }

    static func shouldClearManualUnread(
        previousFocusedPanelId: UUID?,
        nextFocusedPanelId: UUID,
        isManuallyUnread: Bool,
        markedAt: Date?,
        now: Date = Date(),
        sameTabGraceInterval: TimeInterval = manualUnreadFocusGraceInterval
    ) -> Bool {
        guard isManuallyUnread else { return false }

        if let previousFocusedPanelId, previousFocusedPanelId != nextFocusedPanelId {
            return true
        }

        guard let markedAt else { return true }
        return now.timeIntervalSince(markedAt) >= sameTabGraceInterval
    }

    static func shouldShowUnreadIndicator(hasUnreadNotification: Bool, isManuallyUnread: Bool) -> Bool {
        hasUnreadNotification || isManuallyUnread
    }

    // MARK: - Title Management

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    func applyProcessTitle(_ title: String) {
        processTitle = title
        guard customTitle == nil else { return }
        self.title = title
    }

    func setCustomColor(_ hex: String?) {
        if let hex {
            customColor = WorkspaceTabColorSettings.normalizedHex(hex)
        } else {
            customColor = nil
        }
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            self.title = processTitle
        } else {
            customTitle = trimmed
            self.title = trimmed
        }
    }

    // MARK: - Directory Updates

    func updatePanelDirectory(panelId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if panelDirectories[panelId] != trimmed {
            panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId, currentDirectory != trimmed {
            currentDirectory = trimmed
        }
    }

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        if existing?.branch != branch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
        }
        if panelId == focusedPanelId {
            gitBranch = state
        }
    }

    func clearPanelGitBranch(panelId: UUID) {
        panelGitBranches.removeValue(forKey: panelId)
        if panelId == focusedPanelId {
            gitBranch = nil
        }
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var didMutate = false

        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
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
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

        return didMutate
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
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

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        SidebarBranchOrdering
            .orderedUniqueBranches(
                orderedPanelIds: sidebarOrderedPanelIds(),
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: sidebarOrderedPanelIds(),
            panelBranches: panelGitBranches,
            panelDirectories: panelDirectories,
            defaultDirectory: currentDirectory,
            fallbackBranch: gitBranch
        )
    }

    // MARK: - Panel Operations

    private func seedTerminalInheritanceFontPoints(
        panelId: UUID,
        configTemplate: ghostty_surface_config_s?
    ) {
        guard let fontPoints = configTemplate?.font_size, fontPoints > 0 else { return }
        terminalInheritanceFontPointsByPanelId[panelId] = fontPoints
        lastTerminalConfigInheritanceFontPoints = fontPoints
    }

    private func resolvedTerminalInheritanceFontPoints(
        for terminalPanel: TerminalPanel,
        sourceSurface: ghostty_surface_t,
        inheritedConfig: ghostty_surface_config_s
    ) -> Float? {
        let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
        if let rooted = terminalInheritanceFontPointsByPanelId[terminalPanel.id], rooted > 0 {
            if let runtimePoints, abs(runtimePoints - rooted) > 0.05 {
                // Runtime zoom changed after lineage was seeded (manual zoom on descendant);
                // treat runtime as the new root for future descendants.
                return runtimePoints
            }
            return rooted
        }
        if inheritedConfig.font_size > 0 {
            return inheritedConfig.font_size
        }
        return runtimePoints
    }

    private func rememberTerminalConfigInheritanceSource(_ terminalPanel: TerminalPanel) {
        lastTerminalConfigInheritancePanelId = terminalPanel.id
        if let sourceSurface = terminalPanel.surface.surface,
           let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface) {
            let existing = terminalInheritanceFontPointsByPanelId[terminalPanel.id]
            if existing == nil || abs((existing ?? runtimePoints) - runtimePoints) > 0.05 {
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = runtimePoints
            }
            lastTerminalConfigInheritanceFontPoints =
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] ?? runtimePoints
        }
    }

    func lastRememberedTerminalPanelForConfigInheritance() -> TerminalPanel? {
        guard let panelId = lastTerminalConfigInheritancePanelId else { return nil }
        return terminalPanel(for: panelId)
    }

    func lastRememberedTerminalFontPointsForConfigInheritance() -> Float? {
        lastTerminalConfigInheritanceFontPoints
    }

    /// Candidate terminal panels used as the source when creating inherited Ghostty config.
    /// Preference order:
    /// 1) explicitly preferred terminal panel (when the caller has one),
    /// 2) selected terminal in the target pane,
    /// 3) currently focused terminal in the workspace,
    /// 4) last remembered terminal source,
    /// 5) first terminal tab in the target pane,
    /// 6) deterministic workspace fallback.
    private func terminalPanelConfigInheritanceCandidates(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> [TerminalPanel] {
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        if let preferredPanelId,
           let terminalPanel = terminalPanel(for: preferredPanelId) {
            appendCandidate(terminalPanel)
        }

        if let preferredPaneId,
           let selectedSurfaceId = bonsplitController.selectedTab(inPane: preferredPaneId)?.id,
           let selectedPanelId = panelIdFromSurfaceId(selectedSurfaceId),
           let selectedTerminalPanel = terminalPanel(for: selectedPanelId) {
            appendCandidate(selectedTerminalPanel)
        }

        if let focusedTerminalPanel {
            appendCandidate(focusedTerminalPanel)
        }

        if let rememberedTerminalPanel = lastRememberedTerminalPanelForConfigInheritance() {
            appendCandidate(rememberedTerminalPanel)
        }

        if let preferredPaneId {
            for tab in bonsplitController.tabs(inPane: preferredPaneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let terminalPanel = terminalPanel(for: panelId) else { continue }
                appendCandidate(terminalPanel)
            }
        }

        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        return candidates
    }

    /// Picks the first terminal panel candidate used as the inheritance source.
    func terminalPanelForConfigInheritance(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> TerminalPanel? {
        terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ).first
    }

    private func inheritedTerminalConfig(
        preferredPanelId: UUID? = nil,
        inPane preferredPaneId: PaneID? = nil
    ) -> ghostty_surface_config_s? {
        // Walk candidates in priority order and use the first panel with a live surface.
        // This avoids returning nil when the top candidate exists but is not attached yet.
        for terminalPanel in terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            guard let sourceSurface = terminalPanel.surface.surface else { continue }
            var config = cmuxInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            if let rootedFontPoints = resolvedTerminalInheritanceFontPoints(
                for: terminalPanel,
                sourceSurface: sourceSurface,
                inheritedConfig: config
            ), rootedFontPoints > 0 {
                config.font_size = rootedFontPoints
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = rootedFontPoints
            }
            rememberTerminalConfigInheritanceSource(terminalPanel)
            if config.font_size > 0 {
                lastTerminalConfigInheritanceFontPoints = config.font_size
            }
            return config
        }

        if let fallbackFontPoints = lastTerminalConfigInheritanceFontPoints {
            var config = ghostty_surface_config_new()
            config.font_size = fallbackFontPoints
#if DEBUG
            dlog(
                "zoom.inherit fallback=lastKnownFont context=split font=\(String(format: "%.2f", fallbackFontPoints))"
            )
#endif
            return config
        }

        return nil
    }

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        focus: Bool = true
    ) -> TerminalPanel? {
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }
        let inheritedConfig = inheritedTerminalConfig(preferredPanelId: panelId, inPane: paneId)

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
        // so we can hand it to focusPanel as the "move focus FROM" view.
        let previousHostedView = focusedTerminalPanel?.hostedView

        // Create the split with the new tab already present in the new pane.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

#if DEBUG
        dlog("split.created pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation)")
#endif

        // Suppress the old view's becomeFirstResponder side-effects during SwiftUI reparenting.
        // Without this, reparenting triggers onFocus + ghostty_surface_set_focus on the old view,
        // stealing focus from the new panel and creating model/surface divergence.
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(newPanel.id, previousHostedView: previousHostedView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return newPanel
    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        workingDirectory: String? = nil,
        startupEnvironment: [String: String] = [:]
    ) -> TerminalPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let inheritedConfig = inheritedTerminalConfig(inPane: paneId)

        // Create new terminal panel
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            additionalEnvironment: startupEnvironment,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = newPanel.id

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            newPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }
        return newPanel
    }

    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        focus: Bool = true
    ) -> BrowserPanel? {
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        // Create browser panel
        let browserPanel = BrowserPanel(workspaceId: id, initialURL: url)
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newTab = Bonsplit.Tab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = browserPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Create the split with the browser tab already present.
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        // See newTerminalSplit: suppress old view's becomeFirstResponder during reparenting.
        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(browserPanel.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)

        return browserPanel
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL? = nil,
        focus: Bool? = nil,
        insertAtEnd: Bool = false,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> BrowserPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let browserPanel = BrowserPanel(
            workspaceId: id,
            initialURL: url,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
        )
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id

        // Keyboard/browser-open paths want "new tab at end" regardless of global new-tab placement.
        if insertAtEnd {
            let targetIndex = max(0, bonsplitController.tabs(inPane: paneId).count - 1)
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            browserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }

        installBrowserPanelSubscription(browserPanel)

        return browserPanel
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
        if let tabId = surfaceIdFromPanelId(panelId) {
            if force {
                forceCloseTabIds.insert(tabId)
            }
            // Close the tab in bonsplit (this triggers delegate callback)
            return bonsplitController.closeTab(tabId)
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused, close whichever tab bonsplit marks selected in that focused pane.
        guard focusedPanelId == panelId,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
            return false
        }

        if force {
            forceCloseTabIds.insert(selected.id)
        }
        return bonsplitController.closeTab(selected.id)
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        return bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        }
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId })
    }

    /// Returns the nearest right-side sibling pane for browser placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredBrowserTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        let sourcePaneId = sourcePane.id.uuidString
        let tree = bonsplitController.treeSnapshot()
        guard let path = browserPathToPane(targetPaneId: sourcePaneId, node: tree) else { return nil }

        let layout = bonsplitController.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.branch == .first else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            browserCollectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = bonsplitController.allPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    private enum BrowserPaneBranch {
        case first
        case second
    }

    private struct BrowserPaneBreadcrumb {
        let split: ExternalSplitNode
        let branch: BrowserPaneBranch
    }

    private func browserPathToPane(targetPaneId: String, node: ExternalTreeNode) -> [BrowserPaneBreadcrumb]? {
        switch node {
        case .pane(let paneNode):
            return paneNode.id == targetPaneId ? [] : nil
        case .split(let splitNode):
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.first) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .first))
                return path
            }
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.second) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .second))
                return path
            }
            return nil
        }
    }

    private func browserCollectPaneNodes(node: ExternalTreeNode, into output: inout [ExternalPaneNode]) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            browserCollectPaneNodes(node: splitNode.first, into: &output)
            browserCollectPaneNodes(node: splitNode.second, into: &output)
        }
    }

    private struct BrowserCloseFallbackPlan {
        let orientation: SplitOrientation
        let insertFirst: Bool
        let anchorPaneId: UUID?
    }

    private func stageClosedBrowserRestoreSnapshotIfNeeded(for tab: Bonsplit.Tab, inPane pane: PaneID) {
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let browserPanel = browserPanel(for: panelId),
              let tabIndex = bonsplitController.tabs(inPane: pane).firstIndex(where: { $0.id == tab.id }) else {
            pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tab.id)
            return
        }

        let fallbackPlan = browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString,
            in: bonsplitController.treeSnapshot()
        )
        let resolvedURL = browserPanel.currentURL
            ?? browserPanel.webView.url
            ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))

        pendingClosedBrowserRestoreSnapshots[tab.id] = ClosedBrowserPanelRestoreSnapshot(
            workspaceId: id,
            url: resolvedURL,
            originalPaneId: pane.id,
            originalTabIndex: tabIndex,
            fallbackSplitOrientation: fallbackPlan?.orientation,
            fallbackSplitInsertFirst: fallbackPlan?.insertFirst ?? false,
            fallbackAnchorPaneId: fallbackPlan?.anchorPaneId
        )
    }

    private func clearStagedClosedBrowserRestoreSnapshot(for tabId: TabID) {
        pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
    }

    private func browserCloseFallbackPlan(
        forPaneId targetPaneId: String,
        in node: ExternalTreeNode
    ) -> BrowserCloseFallbackPlan? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            if case .pane(let firstPane) = splitNode.first, firstPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: true,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.second,
                        targetCenter: browserPaneCenter(firstPane)
                    )
                )
            }

            if case .pane(let secondPane) = splitNode.second, secondPane.id == targetPaneId {
                return BrowserCloseFallbackPlan(
                    orientation: splitNode.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    insertFirst: false,
                    anchorPaneId: browserNearestPaneId(
                        in: splitNode.first,
                        targetCenter: browserPaneCenter(secondPane)
                    )
                )
            }

            if let nested = browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.first) {
                return nested
            }
            return browserCloseFallbackPlan(forPaneId: targetPaneId, in: splitNode.second)
        }
    }

    private func browserPaneCenter(_ pane: ExternalPaneNode) -> (x: Double, y: Double) {
        (
            x: pane.frame.x + (pane.frame.width * 0.5),
            y: pane.frame.y + (pane.frame.height * 0.5)
        )
    }

    private func browserNearestPaneId(
        in node: ExternalTreeNode,
        targetCenter: (x: Double, y: Double)?
    ) -> UUID? {
        var panes: [ExternalPaneNode] = []
        browserCollectPaneNodes(node: node, into: &panes)
        guard !panes.isEmpty else { return nil }

        let bestPane: ExternalPaneNode?
        if let targetCenter {
            bestPane = panes.min { lhs, rhs in
                let lhsCenter = browserPaneCenter(lhs)
                let rhsCenter = browserPaneCenter(rhs)
                let lhsDistance = pow(lhsCenter.x - targetCenter.x, 2) + pow(lhsCenter.y - targetCenter.y, 2)
                let rhsDistance = pow(rhsCenter.x - targetCenter.x, 2) + pow(rhsCenter.y - targetCenter.y, 2)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.id < rhs.id
            }
        } else {
            bestPane = panes.first
        }

        guard let bestPane else { return nil }
        return UUID(uuidString: bestPane.id)
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.reorderTab(tabId, toIndex: index) else { return false }

        if let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        guard panels[panelId] != nil else { return nil }
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
        dlog(
            "split.detach.begin ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) activeDetachTxn=\(activeDetachCloseTransactions) " +
            "pendingDetached=\(pendingDetachedSurfaces.count)"
        )
#endif

        detachingTabIds.insert(tabId)
        forceCloseTabIds.insert(tabId)
        activeDetachCloseTransactions += 1
        defer { activeDetachCloseTransactions = max(0, activeDetachCloseTransactions - 1) }
        guard bonsplitController.closeTab(tabId) else {
            detachingTabIds.remove(tabId)
            pendingDetachedSurfaces.removeValue(forKey: tabId)
            forceCloseTabIds.remove(tabId)
#if DEBUG
            dlog(
                "split.detach.fail ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
                "tab=\(tabId.uuid.uuidString.prefix(5)) reason=closeTabRejected elapsedMs=\(debugElapsedMs(since: detachStart))"
            )
#endif
            return nil
        }

        let detached = pendingDetachedSurfaces.removeValue(forKey: tabId)
#if DEBUG
        dlog(
            "split.detach.end ws=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5)) " +
            "tab=\(tabId.uuid.uuidString.prefix(5)) transfer=\(detached != nil ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: detachStart))"
        )
#endif
        return detached
    }

    @discardableResult
    func attachDetachedSurface(
        _ detached: DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> UUID? {
#if DEBUG
        let attachStart = ProcessInfo.processInfo.systemUptime
        dlog(
            "split.attach.begin ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0)"
        )
#endif
        guard bonsplitController.allPaneIds.contains(paneId) else {
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=invalidPane elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }
        guard panels[detached.panelId] == nil else {
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=panelExists elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        panels[detached.panelId] = detached.panel
        if let terminalPanel = detached.panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(id)
        } else if let browserPanel = detached.panel as? BrowserPanel {
            browserPanel.updateWorkspaceId(id)
            installBrowserPanelSubscription(browserPanel)
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let cachedTitle = detached.cachedTitle {
            panelTitles[detached.panelId] = cachedTitle
        }
        if let customTitle = detached.customTitle {
            panelCustomTitles[detached.panelId] = customTitle
        }
        if detached.isPinned {
            pinnedPanelIds.insert(detached.panelId)
        } else {
            pinnedPanelIds.remove(detached.panelId)
        }
        if detached.manuallyUnread {
            manualUnreadPanelIds.insert(detached.panelId)
            manualUnreadMarkedAt[detached.panelId] = .distantPast
        } else {
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
        }

        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            hasCustomTitle: detached.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            kind: detached.kind,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            isPinned: detached.isPinned,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detached.panelId)
            panelDirectories.removeValue(forKey: detached.panelId)
            panelTitles.removeValue(forKey: detached.panelId)
            panelCustomTitles.removeValue(forKey: detached.panelId)
            pinnedPanelIds.remove(detached.panelId)
            manualUnreadPanelIds.remove(detached.panelId)
            manualUnreadMarkedAt.removeValue(forKey: detached.panelId)
            panelSubscriptions.removeValue(forKey: detached.panelId)
#if DEBUG
            dlog(
                "split.attach.fail ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
                "reason=createTabFailed elapsedMs=\(debugElapsedMs(since: attachStart))"
            )
#endif
            return nil
        }

        surfaceIdToPanelId[newTabId] = detached.panelId
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }
        syncPinnedStateForTab(newTabId, panelId: detached.panelId)
        syncUnreadBadgeStateForPanel(detached.panelId)
        normalizePinnedTabs(in: paneId)

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            detached.panel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

#if DEBUG
        dlog(
            "split.attach.end ws=\(id.uuidString.prefix(5)) panel=\(detached.panelId.uuidString.prefix(5)) " +
            "tab=\(newTabId.uuid.uuidString.prefix(5)) pane=\(paneId.id.uuidString.prefix(5)) " +
            "index=\(index.map(String.init) ?? "nil") focus=\(focus ? 1 : 0) " +
            "elapsedMs=\(debugElapsedMs(since: attachStart))"
        )
#endif
        return detached.panelId
    }
    // MARK: - Focus Management

    private func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?
    ) {
        guard let preferredPanelId, panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert()
            scheduleFocusReconcile()
            return
        }

        let generation = beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )

        // Bonsplit splitPane focuses the newly created pane and may emit one delayed
        // didSelect/didFocus callback. Re-assert focus over multiple turns so model
        // focus and AppKit first responder stay aligned with non-focus-intent splits.
        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false
                )
                self.scheduleFocusReconcile()
                self.clearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    private func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        allowPreviousHostedView: Bool
    ) {
        guard matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        guard panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if focusedPanelId == splitPanelId {
            focusPanel(
                preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil
            )
            return
        }

        guard focusedPanelId == preferredPanelId,
              let terminalPanel = terminalPanel(for: preferredPanelId) else {
            return
        }
        terminalPanel.hostedView.ensureFocus(for: id, surfaceId: preferredPanelId)
    }

    func focusPanel(
        _ panelId: UUID,
        previousHostedView: GhosttySurfaceScrollView? = nil,
        trigger: FocusPanelTrigger = .standard
    ) {
        markExplicitFocusIntent(on: panelId)
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let triggerLabel = trigger == .terminalFirstResponder ? "firstResponder" : "standard"
        dlog("focus.panel panel=\(panelId.uuidString.prefix(5)) pane=\(pane) trigger=\(triggerLabel)")
        FocusLogStore.shared.append(
            "Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane) trigger=\(triggerLabel)"
        )
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView ?? focusedTerminalPanel?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == tabId
        }()
        let shouldSuppressReentrantRefocus = trigger == .terminalFirstResponder && selectionAlreadyConverged
#if DEBUG
        if shouldSuppressReentrantRefocus {
            dlog(
                "focus.panel.skipReentrant panel=\(panelId.uuidString.prefix(5)) " +
                "reason=firstResponderAlreadyConverged"
            )
        }
#endif

        if let targetPaneId, !selectionAlreadyConverged {
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
            bonsplitController.selectTab(tabId)
        }

        // Also focus the underlying panel
        if let panel = panels[panelId] {
            if (currentlyFocusedPanelId != panelId || !selectionAlreadyConverged) && !shouldSuppressReentrantRefocus {
                panel.focus()
            }

            if !shouldSuppressReentrantRefocus, let terminalPanel = panel as? TerminalPanel {
                // Avoid re-entrant focus loops when focus was initiated by AppKit first-responder
                // (becomeFirstResponder -> onFocus -> focusPanel).
                if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
                }
            }
        }
        if let targetPaneId, !shouldSuppressReentrantRefocus {
            applyTabSelection(tabId: tabId, inPane: targetPaneId)
        }

        if let browserPanel = panels[panelId] as? BrowserPanel {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: trigger)
        }
    }

    private func maybeAutoFocusBrowserAddressBarOnPanelFocus(
        _ browserPanel: BrowserPanel,
        trigger: FocusPanelTrigger
    ) {
        guard trigger == .standard else { return }
        guard !isCommandPaletteVisibleForWorkspaceWindow() else { return }
        guard !browserPanel.shouldSuppressOmnibarAutofocus() else { return }
        guard browserPanel.isShowingNewTabPage || browserPanel.preferredURLStringForOmnibar() == nil else { return }

        _ = browserPanel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: browserPanel.id)
    }

    private func isCommandPaletteVisibleForWorkspaceWindow() -> Bool {
        guard let app = AppDelegate.shared else {
            return false
        }

        if let manager = app.tabManagerFor(tabId: id),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    func moveFocus(direction: NavigationDirection) {
        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = focusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        bonsplitController.navigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < tabs.count else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane(focus: Bool? = nil) -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalSurface(inPane: focusedPaneId, focus: focus)
    }

    // MARK: - Flash/Notification Support

    func triggerFocusFlash(panelId: UUID) {
        panels[panelId]?.triggerFlash()
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard let terminalPanel = terminalPanel(for: panelId) else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        terminalPanel.triggerFlash()
    }

    func triggerDebugFlash(panelId: UUID) {
        triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: true)
    }

    // MARK: - Portal Lifecycle

    /// Hide all terminal portal views for this workspace.
    /// Called before the workspace is unmounted to prevent portal-hosted terminal
    /// views from covering browser panes in the newly selected workspace.
    func hideAllTerminalPortalViews() {
        for panel in panels.values {
            guard let terminal = panel as? TerminalPanel else { continue }
            terminal.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
        }
    }

    // MARK: - Utility

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalPanel() -> TerminalPanel {
        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: focusedPanelId,
            inPane: bonsplitController.focusedPaneId
        )
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        // Create tab in bonsplit
        if let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        ) {
            surfaceIdToPanelId[newTabId] = newPanel.id
        }

        return newPanel
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for panel in panels.values {
            if let terminalPanel = panel as? TerminalPanel,
               terminalPanel.needsConfirmClose() {
                return true
            }
        }
        return false
    }

    private func reconcileFocusState() {
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalPanel = targetPanel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
        if let dir = panelDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    private func scheduleFocusReconcile() {
#if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    private func reconcileTerminalGeometryPass() -> Bool {
        var needsFollowUpPass = false

        // Flush pending AppKit layout first so terminal-host bounds reflect latest split topology.
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let hostedView = terminalPanel.hostedView
            let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
            let hasSurface = terminalPanel.surface.surface != nil
            let isAttached = hostedView.window != nil && hostedView.superview != nil

            // Split close/reparent churn can transiently detach a surviving terminal view.
            // Force one SwiftUI representable update so the portal binding reattaches it.
            if !isAttached || !hasUsableBounds || !hasSurface {
                terminalPanel.requestViewReattach()
                needsFollowUpPass = true
            }

            hostedView.reconcileGeometryNow()
            terminalPanel.surface.forceRefresh()
        }

        return needsFollowUpPass
    }

    private func runScheduledTerminalGeometryReconcile(remainingPasses: Int) {
        guard remainingPasses > 0 else {
            geometryReconcileScheduled = false
            geometryReconcileNeedsRerun = false
            return
        }

        let needsFollowUpPass = reconcileTerminalGeometryPass()
        let shouldRunAgain = geometryReconcileNeedsRerun || needsFollowUpPass

        if shouldRunAgain, remainingPasses > 1 {
            geometryReconcileNeedsRerun = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.runScheduledTerminalGeometryReconcile(remainingPasses: remainingPasses - 1)
            }
            return
        }

        geometryReconcileScheduled = false
        geometryReconcileNeedsRerun = false
    }

    private func scheduleTerminalGeometryReconcile() {
        guard !geometryReconcileScheduled else {
            geometryReconcileNeedsRerun = true
            return
        }
        geometryReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runScheduledTerminalGeometryReconcile(remainingPasses: 4)
        }
    }

    private func closeTabs(_ tabIds: [TabID], skipPinned: Bool = true) {
        for tabId in tabIds {
            if skipPinned,
               let panelId = panelIdFromSurfaceId(tabId),
               pinnedPanelIds.contains(panelId) {
                continue
            }
            _ = bonsplitController.closeTab(tabId)
        }
    }

    private func tabIdsToLeft(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return [] }
        return Array(tabs.prefix(index).map(\.id))
    }

    private func tabIdsToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }),
              index + 1 < tabs.count else { return [] }
        return Array(tabs.suffix(from: index + 1).map(\.id))
    }

    private func tabIdsToCloseOthers(of anchorTabId: TabID, inPane paneId: PaneID) -> [TabID] {
        bonsplitController.tabs(inPane: paneId)
            .map(\.id)
            .filter { $0 != anchorTabId }
    }

    private func createTerminalToRight(of anchorTabId: TabID, inPane paneId: PaneID) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newTerminalSurface(inPane: paneId, focus: true) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func createBrowserToRight(of anchorTabId: TabID, inPane paneId: PaneID, url: URL? = nil) {
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(inPane: paneId, url: url, focus: true) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func duplicateBrowserToRight(anchorTabId: TabID, inPane paneId: PaneID) {
        guard let panelId = panelIdFromSurfaceId(anchorTabId),
              let browser = browserPanel(for: panelId) else { return }
        createBrowserToRight(of: anchorTabId, inPane: paneId, url: browser.currentURL)
    }

    private func promptRenamePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a custom name for this tab."
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = "Tab name"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        setPanelCustomTitle(panelId: panelId, title: input.stringValue)
    }

    private enum PanelMoveDestination {
        case newWorkspaceInCurrentWindow
        case selectedWorkspaceInNewWindow
        case existingWorkspace(UUID)
    }

    private func promptMovePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let app = AppDelegate.shared else { return }

        let currentWindowId = app.tabManagerFor(tabId: id).flatMap { app.windowId(for: $0) }
        let workspaceTargets = app.workspaceMoveTargets(
            excludingWorkspaceId: id,
            referenceWindowId: currentWindowId
        )

        var options: [(title: String, destination: PanelMoveDestination)] = [
            ("New Workspace in Current Window", .newWorkspaceInCurrentWindow),
            ("Selected Workspace in New Window", .selectedWorkspaceInNewWindow),
        ]
        options.append(contentsOf: workspaceTargets.map { target in
            (target.label, .existingWorkspace(target.workspaceId))
        })

        let alert = NSAlert()
        alert.messageText = "Move Tab"
        alert.informativeText = "Choose a destination for this tab."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for option in options {
            popup.addItem(withTitle: option.title)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selectedIndex = max(0, min(popup.indexOfSelectedItem, options.count - 1))
        let destination = options[selectedIndex].destination

        let moved: Bool
        switch destination {
        case .newWorkspaceInCurrentWindow:
            guard let manager = app.tabManagerFor(tabId: id) else { return }
            let workspace = manager.addWorkspace(select: true)
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspace.id,
                focus: true,
                focusWindow: false
            )

        case .selectedWorkspaceInNewWindow:
            let newWindowId = app.createMainWindow()
            guard let destinationManager = app.tabManagerFor(windowId: newWindowId),
                  let destinationWorkspaceId = destinationManager.selectedTabId else {
                return
            }
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: destinationWorkspaceId,
                focus: true,
                focusWindow: true
            )
            if !moved {
                _ = app.closeMainWindow(windowId: newWindowId)
            }

        case .existingWorkspace(let workspaceId):
            moved = app.moveSurface(
                panelId: panelId,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
            )
        }

        if !moved {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Move Failed"
            failure.informativeText = "cmux could not move this tab to the selected destination."
            failure.addButton(withTitle: "OK")
            _ = failure.runModal()
        }
    }

    private func handleExternalTabDrop(_ request: BonsplitController.ExternalTabDropRequest) -> Bool {
        guard let app = AppDelegate.shared else { return false }
#if DEBUG
        let dropStart = ProcessInfo.processInfo.systemUptime
#endif

        let targetPane: PaneID
        let targetIndex: Int?
        let splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?
#if DEBUG
        let destinationLabel: String
#endif

        switch request.destination {
        case .insert(let paneId, let index):
            targetPane = paneId
            targetIndex = index
            splitTarget = nil
#if DEBUG
            destinationLabel = "insert pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil")"
#endif
        case .split(let paneId, let orientation, let insertFirst):
            targetPane = paneId
            targetIndex = nil
            splitTarget = (orientation, insertFirst)
#if DEBUG
            destinationLabel = "split pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation.rawValue) insertFirst=\(insertFirst ? 1 : 0)"
#endif
        }

        #if DEBUG
        dlog(
            "split.externalDrop.begin ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "sourcePane=\(request.sourcePaneId.id.uuidString.prefix(5)) destination=\(destinationLabel)"
        )
        #endif
        let moved = app.moveBonsplitTab(
            tabId: request.tabId.uuid,
            toWorkspace: id,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: true,
            focusWindow: true
        )
#if DEBUG
        dlog(
            "split.externalDrop.end ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(debugElapsedMs(since: dropStart))"
        )
#endif
        return moved
    }

}

// MARK: - BonsplitDelegate

extension Workspace: BonsplitDelegate {
    @MainActor
    private func confirmClosePanel(for tabId: TabID) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close tab?"
        alert.informativeText = "This will close the current tab."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        // Prefer a sheet if we can find a window, otherwise fall back to modal.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Apply the side-effects of selecting a tab (unfocus others, focus this panel, update state).
    /// bonsplit doesn't always emit didSelectTab for programmatic selection paths (e.g. createTab).
    private func applyTabSelection(tabId: TabID, inPane pane: PaneID) {
        pendingTabSelection = (tabId: tabId, pane: pane)
        guard !isApplyingTabSelection else { return }
        isApplyingTabSelection = true
        defer {
            isApplyingTabSelection = false
            pendingTabSelection = nil
        }

        var iterations = 0
        while let request = pendingTabSelection {
            pendingTabSelection = nil
            iterations += 1
            if iterations > 8 { break }
            applyTabSelectionNow(tabId: request.tabId, inPane: request.pane)
        }
    }

    private func applyTabSelectionNow(tabId: TabID, inPane pane: PaneID) {
        let previousFocusedPanelId = focusedPanelId
        if bonsplitController.allPaneIds.contains(pane) {
            if bonsplitController.focusedPaneId != pane {
                bonsplitController.focusPane(pane)
            }
            if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }),
               bonsplitController.selectedTab(inPane: pane)?.id != tabId {
                bonsplitController.selectTab(tabId)
            }
        }

        let focusedPane: PaneID
        let selectedTabId: TabID
        if let currentPane = bonsplitController.focusedPaneId,
           let currentTabId = bonsplitController.selectedTab(inPane: currentPane)?.id {
            focusedPane = currentPane
            selectedTabId = currentTabId
        } else if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }) {
            focusedPane = pane
            selectedTabId = tabId
            bonsplitController.focusPane(focusedPane)
            bonsplitController.selectTab(selectedTabId)
        } else {
            return
        }

        // Focus the selected panel
        guard let panelId = panelIdFromSurfaceId(selectedTabId),
              let panel = panels[panelId] else {
            return
        }

        if shouldTreatCurrentEventAsExplicitFocusIntent() {
            markExplicitFocusIntent(on: panelId)
        }

        syncPinnedStateForTab(selectedTabId, panelId: panelId)
        syncUnreadBadgeStateForPanel(panelId)

        // Unfocus all other panels
        for (id, p) in panels where id != panelId {
            p.unfocus()
        }

        panel.focus()
        let focusIntentAllowsBrowserOmnibarAutofocus =
            shouldTreatCurrentEventAsExplicitFocusIntent() ||
            TerminalController.socketCommandAllowsInAppFocusMutations()
        if let browserPanel = panel as? BrowserPanel,
           previousFocusedPanelId != panelId || focusIntentAllowsBrowserOmnibarAutofocus {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: .standard)
        }
        if let terminalPanel = panel as? TerminalPanel {
            rememberTerminalConfigInheritanceSource(terminalPanel)
        }
        let isManuallyUnread = manualUnreadPanelIds.contains(panelId)
        let markedAt = manualUnreadMarkedAt[panelId]
        if Self.shouldClearManualUnread(
            previousFocusedPanelId: previousFocusedPanelId,
            nextFocusedPanelId: panelId,
            isManuallyUnread: isManuallyUnread,
            markedAt: markedAt
        ) {
            triggerFocusFlash(panelId: panelId)
            let clearDelay = Self.manualUnreadClearDelayAfterFocusFlash
            if clearDelay <= 0 {
                clearManualUnread(panelId: panelId)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) { [weak self] in
                    self?.clearManualUnread(panelId: panelId)
                }
            }
        }

        // Converge AppKit first responder with bonsplit's selected tab in the focused pane.
        // Without this, keyboard input can remain on a different terminal than the blue tab indicator.
        if let terminalPanel = panel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
        }

        // Update current directory if this is a terminal
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[panelId]

        // Post notification
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: self.id,
                GhosttyNotificationKey.surfaceId: panelId
            ]
        )
    }

    private func beginNonFocusSplitFocusReassert(
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> UInt64 {
        nonFocusSplitFocusReassertGeneration &+= 1
        let generation = nonFocusSplitFocusReassertGeneration
        pendingNonFocusSplitFocusReassert = PendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
        return generation
    }

    private func matchesPendingNonFocusSplitFocusReassert(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> Bool {
        guard let pending = pendingNonFocusSplitFocusReassert else { return false }
        return pending.generation == generation &&
            pending.preferredPanelId == preferredPanelId &&
            pending.splitPanelId == splitPanelId
    }

    private func clearNonFocusSplitFocusReassert(generation: UInt64? = nil) {
        guard let pending = pendingNonFocusSplitFocusReassert else { return }
        if let generation, pending.generation != generation { return }
        pendingNonFocusSplitFocusReassert = nil
    }

    private func shouldTreatCurrentEventAsExplicitFocusIntent() -> Bool {
        guard let eventType = NSApp.currentEvent?.type else { return false }
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .scrollWheel,
             .gesture, .magnify, .rotate, .swipe:
            return true
        default:
            return false
        }
    }

    private func markExplicitFocusIntent(on panelId: UUID) {
        guard let pending = pendingNonFocusSplitFocusReassert,
              pending.splitPanelId == panelId else {
            return
        }
        pendingNonFocusSplitFocusReassert = nil
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseSelection() {
            let tabs = controller.tabs(inPane: pane)
            guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
                return
            }

            let target: TabID? = {
                if idx + 1 < tabs.count { return tabs[idx + 1].id }
                if idx > 0 { return tabs[idx - 1].id }
                return nil
            }()

            if let target {
                postCloseSelectTabId[tab.id] = target
            } else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
            }
        }

        if forceCloseTabIds.contains(tab.id) {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        if let panelId = panelIdFromSurfaceId(tab.id),
           pinnedPanelIds.contains(panelId) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            NSSound.beep()
            return false
        }

        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let terminalPanel = terminalPanel(for: panelId) else {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        // If confirmation is required, Bonsplit will call into this delegate and we must return false.
        // Show an app-level confirmation, then re-attempt the close with forceCloseTabIds to bypass
        // this gating on the second pass.
        if terminalPanel.needsConfirmClose() {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    defer { self.pendingCloseConfirmTabIds.remove(tabId) }

                    // If the tab disappeared while we were scheduling, do nothing.
                    guard self.panelIdFromSurfaceId(tabId) != nil else { return }

                    let confirmed = await self.confirmClosePanel(for: tabId)
                    guard confirmed else { return }

                    self.forceCloseTabIds.insert(tabId)
                    self.bonsplitController.closeTab(tabId)
                }
            }

            return false
        }

        clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
        recordPostCloseSelection()
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseTabIds.remove(tabId)
        let selectTabId = postCloseSelectTabId.removeValue(forKey: tabId)
        let closedBrowserRestoreSnapshot = pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
        let isDetaching = detachingTabIds.remove(tabId) != nil || isDetachingCloseTransaction

        // Clean up our panel
        guard let panelId = panelIdFromSurfaceId(tabId) else {
            #if DEBUG
            NSLog("[Workspace] didCloseTab: no panelId for tabId")
            #endif
            scheduleTerminalGeometryReconcile()
            if !isDetaching {
                scheduleFocusReconcile()
            }
            return
        }

        #if DEBUG
        NSLog("[Workspace] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        let panel = panels[panelId]

        if isDetaching, let panel {
            let browserPanel = panel as? BrowserPanel
            let cachedTitle = panelTitles[panelId]
            let transferFallbackTitle = cachedTitle ?? panel.displayTitle
            pendingDetachedSurfaces[tabId] = DetachedSurfaceTransfer(
                panelId: panelId,
                panel: panel,
                title: resolvedPanelTitle(panelId: panelId, fallback: transferFallbackTitle),
                icon: panel.displayIcon,
                iconImageData: browserPanel?.faviconPNGData,
                kind: surfaceKind(for: panel),
                isLoading: browserPanel?.isLoading ?? false,
                isPinned: pinnedPanelIds.contains(panelId),
                directory: panelDirectories[panelId],
                cachedTitle: cachedTitle,
                customTitle: panelCustomTitles[panelId],
                manuallyUnread: manualUnreadPanelIds.contains(panelId)
            )
        } else {
            if let closedBrowserRestoreSnapshot {
                onClosedBrowserPanel?(closedBrowserRestoreSnapshot)
            }
            panel?.close()
        }

        panels.removeValue(forKey: panelId)
        surfaceIdToPanelId.removeValue(forKey: tabId)
        panelDirectories.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        terminalInheritanceFontPointsByPanelId.removeValue(forKey: panelId)
        if lastTerminalConfigInheritancePanelId == panelId {
            lastTerminalConfigInheritancePanelId = nil
        }

        // Keep the workspace invariant for normal close paths.
        // Detach/move flows intentionally allow a temporary empty workspace so AppDelegate can
        // prune the source workspace/window after the tab is attached elsewhere.
        if panels.isEmpty {
            if isDetaching {
                scheduleTerminalGeometryReconcile()
                return
            }

            let replacement = createReplacementTerminalPanel()
            if let replacementTabId = surfaceIdFromPanelId(replacement.id),
               let replacementPane = bonsplitController.allPaneIds.first {
                bonsplitController.focusPane(replacementPane)
                bonsplitController.selectTab(replacementTabId)
                applyTabSelection(tabId: replacementTabId, inPane: replacementPane)
            }
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        if let selectTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }),
           bonsplitController.focusedPaneId == pane {
            // Keep selection/focus convergence in the same close transaction to avoid a transient
            // frame where the pane has no selected content.
            bonsplitController.selectTab(selectTabId)
            applyTabSelection(tabId: selectTabId, inPane: pane)
        } else if let focusedPane = bonsplitController.focusedPaneId,
                  let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
            // When closing the last tab in a pane, Bonsplit may focus a different pane and skip
            // emitting didSelectTab. Re-apply the focused selection so sidebar state stays in sync.
            applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
        }

        if bonsplitController.allPaneIds.contains(pane) {
            normalizePinnedTabs(in: pane)
        }
        scheduleTerminalGeometryReconcile()
        if !isDetaching {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        applyTabSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let sincePrev: String
        if debugLastDidMoveTabTimestamp > 0 {
            sincePrev = String(format: "%.2f", (now - debugLastDidMoveTabTimestamp) * 1000)
        } else {
            sincePrev = "first"
        }
        debugLastDidMoveTabTimestamp = now
        debugDidMoveTabEventCount += 1
        let movedPanelId = panelIdFromSurfaceId(tab.id)
        let movedPanel = movedPanelId?.uuidString.prefix(5) ?? "unknown"
        let selectedBefore = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneBefore = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        dlog(
            "split.moveTab idx=\(debugDidMoveTabEventCount) dtSincePrevMs=\(sincePrev) panel=\(movedPanel) " +
            "from=\(source.id.uuidString.prefix(5)) to=\(destination.id.uuidString.prefix(5)) " +
            "sourceTabs=\(controller.tabs(inPane: source).count) destTabs=\(controller.tabs(inPane: destination).count)"
        )
        dlog(
            "split.moveTab.state.before idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedBefore) focusedPane=\(focusedPaneBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: destination)
#if DEBUG
        let selectedAfter = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneAfter = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        let movedPanelFocused = (movedPanelId != nil && movedPanelId == focusedPanelId) ? 1 : 0
        dlog(
            "split.moveTab.state.after idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedAfter) focusedPane=\(focusedPaneAfter) focusedPanel=\(focusedPanelAfter) " +
            "movedFocused=\(movedPanelFocused)"
        )
#endif
        normalizePinnedTabs(in: source)
        normalizePinnedTabs(in: destination)
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        FocusLogStore.shared.append(
            "Workspace.didFocusPane paneId=\(pane.id.uuidString) tabId=\(tab.id) focusedPane=\(controller.focusedPaneId?.id.uuidString ?? "nil")"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = panelIdFromSurfaceId(tab.id),
           let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        let closedPanelIds = pendingPaneClosePanelIds.removeValue(forKey: paneId.id) ?? []
        let shouldScheduleFocusReconcile = !isDetachingCloseTransaction

        if !closedPanelIds.isEmpty {
            for panelId in closedPanelIds {
                panels[panelId]?.close()
                panels.removeValue(forKey: panelId)
                panelDirectories.removeValue(forKey: panelId)
                panelGitBranches.removeValue(forKey: panelId)
                panelTitles.removeValue(forKey: panelId)
                panelCustomTitles.removeValue(forKey: panelId)
                pinnedPanelIds.remove(panelId)
                manualUnreadPanelIds.remove(panelId)
                panelSubscriptions.removeValue(forKey: panelId)
                surfaceTTYNames.removeValue(forKey: panelId)
                surfaceListeningPorts.removeValue(forKey: panelId)
                restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
                PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
            }

            let closedSet = Set(closedPanelIds)
            surfaceIdToPanelId = surfaceIdToPanelId.filter { !closedSet.contains($0.value) }
            recomputeListeningPorts()

            if let focusedPane = bonsplitController.focusedPaneId,
               let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
                applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
            } else if shouldScheduleFocusReconcile {
                scheduleFocusReconcile()
            }
        }

        scheduleTerminalGeometryReconcile()
        if shouldScheduleFocusReconcile {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let tabs = controller.tabs(inPane: pane)
        for tab in tabs {
            if forceCloseTabIds.contains(tab.id) { continue }
            if let panelId = panelIdFromSurfaceId(tab.id),
               let terminalPanel = terminalPanel(for: panelId),
               terminalPanel.needsConfirmClose() {
                pendingPaneClosePanelIds.removeValue(forKey: pane.id)
                return false
            }
        }
        pendingPaneClosePanelIds[pane.id] = tabs.compactMap { panelIdFromSurfaceId($0.id) }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
#if DEBUG
        let panelKindForTab: (TabID) -> String = { tabId in
            guard let panelId = self.panelIdFromSurfaceId(tabId),
                  let panel = self.panels[panelId] else { return "placeholder" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }
        let paneKindSummary: (PaneID) -> String = { paneId in
            let tabs = controller.tabs(inPane: paneId)
            guard !tabs.isEmpty else { return "-" }
            return tabs.map { tab in
                String(panelKindForTab(tab.id).prefix(1))
            }.joined(separator: ",")
        }
        let originalSelectedKind = controller.selectedTab(inPane: originalPane).map { panelKindForTab($0.id) } ?? "none"
        let newSelectedKind = controller.selectedTab(inPane: newPane).map { panelKindForTab($0.id) } ?? "none"
        dlog(
            "split.didSplit original=\(originalPane.id.uuidString.prefix(5)) new=\(newPane.id.uuidString.prefix(5)) " +
            "orientation=\(orientation) programmatic=\(isProgrammaticSplit ? 1 : 0) " +
            "originalTabs=\(controller.tabs(inPane: originalPane).count) newTabs=\(controller.tabs(inPane: newPane).count) " +
            "originalSelected=\(originalSelectedKind) newSelected=\(newSelectedKind) " +
            "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
        )
#endif
        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else {
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmux, this is undesirable:
        // it creates a pane with no real surfaces and leaves an "Empty" tab in the tab bar.
        //
        // Replace placeholder-only source panes with a real terminal surface, then drop the
        // placeholder tabs so the UI stays consistent and pane lists don't contain empties.
        if !controller.tabs(inPane: newPane).isEmpty {
            let originalTabs = controller.tabs(inPane: originalPane)
            let hasRealSurface = originalTabs.contains { panelIdFromSurfaceId($0.id) != nil }
#if DEBUG
            dlog(
                "split.didSplit.drag original=\(originalPane.id.uuidString.prefix(5)) " +
                "new=\(newPane.id.uuidString.prefix(5)) originalTabs=\(originalTabs.count) " +
                "newTabs=\(controller.tabs(inPane: newPane).count) hasRealSurface=\(hasRealSurface ? 1 : 0) " +
                "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
            )
#endif
            if !hasRealSurface {
                let placeholderTabs = originalTabs.filter { panelIdFromSurfaceId($0.id) == nil }
#if DEBUG
                dlog(
                    "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                    "action=reusePlaceholder placeholderCount=\(placeholderTabs.count)"
                )
#endif
                if let replacementTab = placeholderTabs.first {
                    // Keep the existing placeholder tab identity and replace only the panel mapping.
                    // This avoids an extra create+close tab churn that can transiently render an
                    // empty pane during drag-to-split of a single-tab pane.
                    let inheritedConfig = inheritedTerminalConfig(inPane: originalPane)

                    let replacementPanel = TerminalPanel(
                        workspaceId: id,
                        context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                        configTemplate: inheritedConfig,
                        portOrdinal: portOrdinal
                    )
                    panels[replacementPanel.id] = replacementPanel
                    panelTitles[replacementPanel.id] = replacementPanel.displayTitle
                    seedTerminalInheritanceFontPoints(panelId: replacementPanel.id, configTemplate: inheritedConfig)
                    surfaceIdToPanelId[replacementTab.id] = replacementPanel.id

                    bonsplitController.updateTab(
                        replacementTab.id,
                        title: replacementPanel.displayTitle,
                        icon: .some(replacementPanel.displayIcon),
                        iconImageData: .some(nil),
                        kind: .some(SurfaceKind.terminal),
                        hasCustomTitle: false,
                        isDirty: replacementPanel.isDirty,
                        showsNotificationBadge: false,
                        isLoading: false,
                        isPinned: false
                    )

                    for extraPlaceholder in placeholderTabs.dropFirst() {
                        bonsplitController.closeTab(extraPlaceholder.id)
                    }
                } else {
#if DEBUG
                    dlog(
                        "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                        "fallback=createTerminalAndDropPlaceholders"
                    )
#endif
                    _ = newTerminalSurface(inPane: originalPane, focus: false)
                    for tab in controller.tabs(inPane: originalPane) {
                        if panelIdFromSurfaceId(tab.id) == nil {
                            bonsplitController.closeTab(tab.id)
                        }
                    }
                }
            }
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // Get the focused terminal in the original pane to inherit config from
        guard let sourceTabId = controller.selectedTab(inPane: originalPane)?.id,
              let sourcePanelId = panelIdFromSurfaceId(sourceTabId),
              terminalPanel(for: sourcePanelId) != nil else { return }

#if DEBUG
        dlog(
            "split.didSplit.autoCreate pane=\(newPane.id.uuidString.prefix(5)) " +
            "fromPane=\(originalPane.id.uuidString.prefix(5)) sourcePanel=\(sourcePanelId.uuidString.prefix(5))"
        )
#endif

        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: sourcePanelId,
            inPane: originalPane
        )

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: newPane
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return
        }

        surfaceIdToPanelId[newTabId] = newPanel.id
        normalizePinnedTabs(in: newPane)
#if DEBUG
        dlog(
            "split.didSplit.autoCreate.done pane=\(newPane.id.uuidString.prefix(5)) " +
            "panel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // `createTab` selects the new tab but does not emit didSelectTab; schedule an explicit
        // selection so our focus/unfocus logic runs after this delegate callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonsplitController.focusedPaneId == newPane {
                self.bonsplitController.selectTab(newTabId)
            }
            self.scheduleTerminalGeometryReconcile()
            self.scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        switch kind {
        case "terminal":
            _ = newTerminalSurface(inPane: pane)
        case "browser":
            _ = newBrowserSurface(inPane: pane)
        default:
            _ = newTerminalSurface(inPane: pane)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        switch action {
        case .rename:
            promptRenamePanel(tabId: tab.id)
        case .clearName:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            setPanelCustomTitle(panelId: panelId, title: nil)
        case .closeToLeft:
            closeTabs(tabIdsToLeft(of: tab.id, inPane: pane))
        case .closeToRight:
            closeTabs(tabIdsToRight(of: tab.id, inPane: pane))
        case .closeOthers:
            closeTabs(tabIdsToCloseOthers(of: tab.id, inPane: pane))
        case .move:
            promptMovePanel(tabId: tab.id)
        case .newTerminalToRight:
            createTerminalToRight(of: tab.id, inPane: pane)
        case .newBrowserToRight:
            createBrowserToRight(of: tab.id, inPane: pane)
        case .reload:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browser = browserPanel(for: panelId) else { return }
            browser.reload()
        case .duplicate:
            duplicateBrowserToRight(anchorTabId: tab.id, inPane: pane)
        case .togglePin:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            let shouldPin = !pinnedPanelIds.contains(panelId)
            setPanelPinned(panelId: panelId, pinned: shouldPin)
        case .markAsRead:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            clearManualUnread(panelId: panelId)
        case .markAsUnread:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelUnread(panelId)
        @unknown default:
            break
        }
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        _ = snapshot
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}

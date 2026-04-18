import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

#if DEBUG
private func debugWorkspaceDescriptionPreview(_ text: String?, limit: Int = 120) -> String {
    guard let text else { return "nil" }
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    if escaped.count <= limit {
        return escaped
    }
    return "\(escaped.prefix(limit))..."
}
#endif

struct CmuxSurfaceConfigTemplate {
    var fontSize: Float32 = 0
    var workingDirectory: String?
    var command: String?
    var environmentVariables: [String: String] = [:]
    var initialInput: String?
    var waitAfterCommand: Bool = false

    init() {}

    init(cConfig: ghostty_surface_config_s) {
        fontSize = cConfig.font_size
        if let workingDirectory = cConfig.working_directory {
            self.workingDirectory = String(cString: workingDirectory, encoding: .utf8)
        }
        if let command = cConfig.command {
            self.command = String(cString: command, encoding: .utf8)
        }
        if let initialInput = cConfig.initial_input {
            self.initialInput = String(cString: initialInput, encoding: .utf8)
        }
        if cConfig.env_var_count > 0, let envVars = cConfig.env_vars {
            for index in 0..<Int(cConfig.env_var_count) {
                let envVar = envVars[index]
                if let key = String(cString: envVar.key, encoding: .utf8),
                   let value = String(cString: envVar.value, encoding: .utf8) {
                    environmentVariables[key] = value
                }
            }
        }
        waitAfterCommand = cConfig.wait_after_command
    }
}

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

private func cmuxPointerAppearsLive(_ pointer: UnsafeMutableRawPointer?) -> Bool {
    guard let pointer,
          malloc_zone_from_ptr(pointer) != nil else {
        return false
    }
    return malloc_size(pointer) > 0
}

func cmuxSurfacePointerAppearsLive(_ surface: ghostty_surface_t) -> Bool {
    // Best-effort check: reject pointers that no longer belong to an active
    // malloc zone allocation. A Swift wrapper around `ghostty_surface_t` can
    // remain non-nil after the backing native surface has already been freed.
    cmuxPointerAppearsLive(surface)
}

func cmuxCurrentSurfaceFontSizePoints(_ surface: ghostty_surface_t) -> Float? {
    guard cmuxSurfacePointerAppearsLive(surface) else {
        return nil
    }

    guard let quicklookFont = ghostty_surface_quicklook_font(surface) else {
        return nil
    }

    let ctFont = Unmanaged<CTFont>.fromOpaque(quicklookFont).takeUnretainedValue()
    let points = Float(CTFontGetSize(ctFont))
    guard points > 0 else { return nil }
    return points
}

func cmuxInheritedSurfaceConfig(
    sourceSurface: ghostty_surface_t,
    context: ghostty_surface_context_e
) -> CmuxSurfaceConfigTemplate {
    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    var config = CmuxSurfaceConfigTemplate(cConfig: inherited)

    // Make runtime zoom inheritance explicit, even when Ghostty's
    // inherit-font-size config is disabled.
    let runtimePoints = cmuxCurrentSurfaceFontSizePoints(sourceSurface)
    if let points = runtimePoints {
        config.fontSize = points
    }

#if DEBUG
    let inheritedText = String(format: "%.2f", inherited.font_size)
    let runtimeText = runtimePoints.map { String(format: "%.2f", $0) } ?? "nil"
    let finalText = String(format: "%.2f", config.fontSize)
    dlog(
        "zoom.inherit context=\(cmuxSurfaceContextName(context)) " +
        "inherited=\(inheritedText) runtime=\(runtimeText) final=\(finalText)"
    )
#endif

    return config
}

struct SidebarStatusEntry: Equatable {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let url: URL?
    let priority: Int
    let format: SidebarMetadataFormat
    let timestamp: Date

    init(
        key: String,
        value: String,
        icon: String? = nil,
        color: String? = nil,
        url: URL? = nil,
        priority: Int = 0,
        format: SidebarMetadataFormat = .plain,
        timestamp: Date = Date()
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.url = url
        self.priority = priority
        self.format = format
        self.timestamp = timestamp
    }
}

struct SidebarMetadataBlock: Equatable {
    let key: String
    let markdown: String
    let priority: Int
    let timestamp: Date
}

enum SidebarMetadataFormat: String {
    case plain
    case markdown
}

private struct SessionPaneRestoreEntry {
    let paneId: PaneID
    let snapshot: SessionPaneLayoutSnapshot
}

private enum RemoteDropUploadError: LocalizedError {
    case unavailable
    case invalidFileURL
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "error.remoteDrop.unavailable",
                defaultValue: "Remote drop is unavailable."
            )
        case .invalidFileURL:
            String(
                localized: "error.remoteDrop.invalidFileURL",
                defaultValue: "Dropped item is not a file URL."
            )
        case .uploadFailed(let detail):
            String.localizedStringWithFormat(
                String(
                    localized: "error.remoteDrop.uploadFailed",
                    defaultValue: "Failed to upload dropped file: %@"
                ),
                detail
            )
        }
    }
}

struct WorkspaceRemoteDaemonManifest: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let goOS: String
        let goArch: String
        let assetName: String
        let downloadURL: String
        let sha256: String
    }

    let schemaVersion: Int
    let appVersion: String
    let releaseTag: String
    let releaseURL: String
    let checksumsAssetName: String
    let checksumsURL: String
    let entries: [Entry]

    func entry(goOS: String, goArch: String) -> Entry? {
        entries.first { $0.goOS == goOS && $0.goArch == goArch }
    }
}

extension Workspace {
    nonisolated static let remoteDaemonManifestInfoKey = WorkspaceRemoteSessionController.remoteDaemonManifestInfoKey

    nonisolated static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        WorkspaceRemoteSessionController.remoteDaemonManifest(from: infoDictionary)
    }

    nonisolated static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try WorkspaceRemoteSessionController.remoteDaemonCachedBinaryURL(
            version: version,
            goOS: goOS,
            goArch: goArch,
            fileManager: fileManager
        )
    }

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
            customDescription: customDescription,
            customColor: customColor,
            isPinned: isPinned,
            terminalScrollBarHidden: terminalScrollBarHidden ? true : nil,
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
        setCustomDescription(snapshot.customDescription)
        setCustomColor(snapshot.customColor)
        isPinned = snapshot.isPinned
        setTerminalScrollBarHidden(snapshot.terminalScrollBarHidden ?? false)

        // Status entries and agent PIDs are ephemeral runtime state tied to running
        // processes (e.g. claude_code "Running"). Don't restore them across app
        // restarts because the processes that set them are gone.
        statusEntries.removeAll()
        agentPIDs.removeAll()
        agentListeningPorts.removeAll()
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
        let listeningPorts: [Int]
        if remoteDetectedSurfaceIds.contains(panelId) || isRemoteTerminalSurface(panelId) {
            listeningPorts = []
        } else {
            listeningPorts = (surfaceListeningPorts[panelId] ?? []).sorted()
        }
        let ttyName = surfaceTTYNames[panelId]

        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        let markdownSnapshot: SessionMarkdownPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminalPanel = panel as? TerminalPanel else { return nil }
            let shouldPersistScrollback = terminalPanel.shouldPersistScrollbackForSessionSnapshot()
            let capturedScrollback = includeScrollback && shouldPersistScrollback
                ? TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminalPanel,
                    includeScrollback: true,
                    lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                )
                : nil
            let resolvedScrollback = terminalSnapshotScrollback(
                panelId: panelId,
                capturedScrollback: capturedScrollback,
                includeScrollback: includeScrollback,
                allowFallbackScrollback: shouldPersistScrollback
            )
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: panelDirectories[panelId],
                scrollback: resolvedScrollback
            )
            browserSnapshot = nil
            markdownSnapshot = nil
        case .browser:
            guard let browserPanel = panel as? BrowserPanel else { return nil }
            terminalSnapshot = nil
            let historySnapshot = browserPanel.sessionNavigationHistorySnapshot()
            browserSnapshot = SessionBrowserPanelSnapshot(
                urlString: browserPanel.preferredURLStringForOmnibar(),
                profileID: browserPanel.profileID,
                shouldRenderWebView: browserPanel.shouldRenderWebView,
                pageZoom: Double(browserPanel.currentPageZoomFactor()),
                developerToolsVisible: browserPanel.isDeveloperToolsVisible(),
                backHistoryURLStrings: historySnapshot.backHistoryURLStrings,
                forwardHistoryURLStrings: historySnapshot.forwardHistoryURLStrings
            )
            markdownSnapshot = nil
        case .markdown:
            guard let markdownPanel = panel as? MarkdownPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = SessionMarkdownPanelSnapshot(filePath: markdownPanel.filePath)
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
            browser: browserSnapshot,
            markdown: markdownSnapshot
        )
    }

    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        if let captured = SessionPersistencePolicy.truncatedScrollback(capturedScrollback) {
            return captured
        }
        guard allowFallbackScrollback else { return nil }
        return SessionPersistencePolicy.truncatedScrollback(fallbackScrollback)
    }

    private func terminalSnapshotScrollback(
        panelId: UUID,
        capturedScrollback: String?,
        includeScrollback: Bool,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        guard includeScrollback else { return nil }
        let fallback = allowFallbackScrollback ? restoredTerminalScrollbackByPanelId[panelId] : nil
        let resolved = Self.resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallback,
            allowFallbackScrollback: allowFallbackScrollback
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
            guard let browserPanel = newBrowserSurface(
                inPane: paneId,
                url: nil,
                focus: false,
                preferredProfileID: snapshot.browser?.profileID
            ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: browserPanel.id)
            return browserPanel.id
        case .markdown:
            guard let filePath = snapshot.markdown?.filePath,
                  let markdownPanel = newMarkdownSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: markdownPanel.id)
            return markdownPanel.id
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
        syncRemotePortScanTTYs()

        if let browserSnapshot = snapshot.browser,
           let browserPanel = browserPanel(for: panelId) {
            let pageZoom = CGFloat(max(0.25, min(5.0, browserSnapshot.pageZoom)))
            if pageZoom.isFinite {
                _ = browserPanel.setPageZoomFactor(pageZoom)
            }

            browserPanel.restoreSessionSnapshot(browserSnapshot)

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

// MARK: - cmux.json custom layout

extension Workspace {

    func applyCustomLayout(_ layout: CmuxLayoutNode, baseCwd: String) {
        guard let rootPaneId = bonsplitController.allPaneIds.first else { return }

        var leaves: [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition])] = []
        buildCustomLayoutTree(layout, inPane: rootPaneId, leaves: &leaves)

        // First leaf reuses the initial terminal created by addWorkspace;
        // subsequent leaves were created via newTerminalSplit which also seeds
        // a placeholder terminal.
        var focusPanelId: UUID?
        for leaf in leaves {
            populateCustomPane(leaf.paneId, surfaces: leaf.surfaces, baseCwd: baseCwd, focusPanelId: &focusPanelId)
        }

        let liveRoot = bonsplitController.treeSnapshot()
        applyCustomDividerPositions(configNode: layout, liveNode: liveRoot)

        if let focusPanelId {
            focusPanel(focusPanelId)
        }
    }

    private func buildCustomLayoutTree(
        _ node: CmuxLayoutNode,
        inPane paneId: PaneID,
        leaves: inout [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition])]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append((paneId: paneId, surfaces: pane.surfaces))

        case .split(let split):
            guard split.children.count == 2 else {
                NSLog("[CmuxConfig] split node requires exactly 2 children, got %d", split.children.count)
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

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
                      orientation: split.splitOrientation,
                      insertFirst: false,
                      focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append((paneId: paneId, surfaces: []))
                return
            }

            buildCustomLayoutTree(split.children[0], inPane: paneId, leaves: &leaves)
            buildCustomLayoutTree(split.children[1], inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func populateCustomPane(
        _ paneId: PaneID,
        surfaces: [CmuxSurfaceDefinition],
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }

        guard !surfaces.isEmpty else { return }

        let firstSurface = surfaces[0]
        if let placeholderPanelId = existingPanelIds.first {
            configureExistingSurface(
                panelId: placeholderPanelId,
                inPane: paneId,
                surface: firstSurface,
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            )
        }

        for surfaceIndex in 1..<surfaces.count {
            createNewSurface(
                inPane: paneId,
                surface: surfaces[surfaceIndex],
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId
            )
        }
    }

    private func configureExistingSurface(
        panelId: UUID,
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        switch surface.type {
        case .terminal where surface.cwd != nil || surface.env != nil:
            // Placeholder can't change cwd/env — replace it
            let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            if let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
                if let command = surface.command { sendInputWhenReady(command + "\n", to: panel) }
            }

        case .terminal:
            if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
            if surface.focus == true { focusPanelId = panelId }
            if let command = surface.command, let terminal = terminalPanel(for: panelId) {
                sendInputWhenReady(command + "\n", to: terminal)
            }

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            if let panel = newBrowserSurface(inPane: paneId, url: url, focus: false) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }
        }
    }

    private func createNewSurface(
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?
    ) {
        switch surface.type {
        case .terminal:
            let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            if let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                startupEnvironment: surface.env ?? [:]
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
                if let command = surface.command { sendInputWhenReady(command + "\n", to: panel) }
            }

        case .browser:
            let url = surface.url.flatMap { URL(string: $0) }
            if let panel = newBrowserSurface(inPane: paneId, url: url, focus: false) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }
        }
    }

    private func applyCustomDividerPositions(
        configNode: CmuxLayoutNode,
        liveNode: ExternalTreeNode
    ) {
        switch (configNode, liveNode) {
        case (.split(let configSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(configSplit.clampedSplitPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            if configSplit.children.count == 2 {
                applyCustomDividerPositions(configNode: configSplit.children[0], liveNode: liveSplit.first)
                applyCustomDividerPositions(configNode: configSplit.children[1], liveNode: liveSplit.second)
            }
        default:
            break
        }
    }

    private func sendInputWhenReady(_ text: String, to panel: TerminalPanel) {
        if panel.surface.surface != nil {
            panel.sendInput(text)
            return
        }

        var resolved = false
        var observer: NSObjectProtocol?

        observer = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: panel.surface,
            queue: .main
        ) { [weak panel] _ in
            guard !resolved, let panel else { return }
            resolved = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            panel.sendInput(text)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard !resolved else { return }
            resolved = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            NSLog("[CmuxConfig] surface not ready after 3s, dropping command (%d chars)", text.count)
        }
    }
}

final class WorkspaceRemoteDaemonPendingCallRegistry {
    final class PendingCall {
        let id: Int
        fileprivate let semaphore = DispatchSemaphore(value: 0)
        fileprivate var response: [String: Any]?
        fileprivate var failureMessage: String?

        fileprivate init(id: Int) {
            self.id = id
        }
    }

    enum WaitOutcome {
        case response([String: Any])
        case failure(String)
        case missing
        case timedOut
    }

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.pending.\(UUID().uuidString)")
    private var nextRequestID = 1
    private var pendingCalls: [Int: PendingCall] = [:]

    func reset() {
        queue.sync {
            nextRequestID = 1
            pendingCalls.removeAll(keepingCapacity: false)
        }
    }

    func register() -> PendingCall {
        queue.sync {
            let call = PendingCall(id: nextRequestID)
            nextRequestID += 1
            pendingCalls[call.id] = call
            return call
        }
    }

    @discardableResult
    func resolve(id: Int, payload: [String: Any]) -> Bool {
        queue.sync {
            guard let pendingCall = pendingCalls[id] else { return false }
            pendingCall.response = payload
            pendingCall.semaphore.signal()
            return true
        }
    }

    func failAll(_ message: String) {
        queue.sync {
            let calls = Array(pendingCalls.values)
            for call in calls {
                guard call.response == nil, call.failureMessage == nil else { continue }
                call.failureMessage = message
                call.semaphore.signal()
            }
        }
    }

    func remove(_ call: PendingCall) {
        _ = queue.sync {
            pendingCalls.removeValue(forKey: call.id)
        }
    }

    func wait(for call: PendingCall, timeout: TimeInterval) -> WaitOutcome {
        if call.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            _ = queue.sync {
                pendingCalls.removeValue(forKey: call.id)
            }
            // A response can win the race immediately before timeout cleanup removes the call.
            // Drain any late signal so DispatchSemaphore is not deallocated with a positive count.
            _ = call.semaphore.wait(timeout: .now())
            return .timedOut
        }

        return queue.sync {
            guard let pendingCall = pendingCalls.removeValue(forKey: call.id) else {
                return .missing
            }
            if let failure = pendingCall.failureMessage {
                return .failure(failure)
            }
            guard let response = pendingCall.response else {
                return .missing
            }
            return .response(response)
        }
    }
}

enum WorkspaceRemoteSSHBatchCommandBuilder {
    private static let batchSSHControlOptionKeys: Set<String> = [
        "controlmaster",
        "controlpersist",
    ]

    static func daemonTransportArguments(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String
    ) -> [String] {
        let script = "exec \(shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(shellSingleQuoted(script))"
        return ["-T"]
            + batchArguments(configuration: configuration)
            + ["-o", "RequestTTY=no", configuration.destination, command]
    }

    static func reverseRelayControlMasterArguments(
        configuration: WorkspaceRemoteConfiguration,
        controlCommand: String,
        forwardSpec: String
    ) -> [String]? {
        guard let controlPath = sshOptionValue(named: "ControlPath", in: configuration.sshOptions)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return nil
        }

        var args = batchArguments(configuration: configuration)
        args += ["-O", controlCommand, "-R", forwardSpec, configuration.destination]
        return args
    }

    private static func batchArguments(configuration: WorkspaceRemoteConfiguration) -> [String] {
        let effectiveSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        args += ["-o", "BatchMode=yes"]
        // Batch helpers may reuse an existing ControlPath, but must not negotiate a new master.
        args += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            if sshOptionKey(option) == loweredKey {
                return true
            }
        }
        return false
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private static func backgroundSSHOptions(_ options: [String]) -> [String] {
        normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    private static func sshOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in normalizedSSHOptions(options) {
            let parts = option.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "=" || $0.isWhitespace }
            )
            guard parts.count == 2, parts[0].lowercased() == loweredKey else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private final class WorkspaceRemoteDaemonRPCClient {
    private static let maxStdoutBufferBytes = 256 * 1024
    static let requiredProxyStreamCapability = "proxy.stream.push"

    enum StreamEvent {
        case data(Data)
        case eof(Data)
        case error(String)
    }

    private struct StreamSubscription {
        let queue: DispatchQueue
        let handler: (StreamEvent) -> Void
    }

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let onUnexpectedTermination: (String) -> Void
    private let writeQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.write.\(UUID().uuidString)")
    private let stateQueue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-rpc.state.\(UUID().uuidString)")
    private let pendingCalls = WorkspaceRemoteDaemonPendingCallRegistry()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var isClosed = true
    private var shouldReportTermination = true

    private var stdoutBuffer = Data()
    private var stderrBuffer = ""
    private var streamSubscriptions: [String: StreamSubscription] = [:]

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUnexpectedTermination: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.onUnexpectedTermination = onUnexpectedTermination
    }

    func start() throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        stateQueue.sync {
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.daemonArguments(configuration: configuration, remotePath: remotePath)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.stateQueue.async {
                self?.consumeStdoutData(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.stateQueue.async {
                self?.consumeStderrData(data)
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async {
                self?.handleProcessTermination(terminated)
            }
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch SSH daemon transport: \(error.localizedDescription)",
            ])
        }

        stateQueue.sync {
            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
            self.stdoutHandle = stdoutPipe.fileHandleForReading
            self.stderrHandle = stderrPipe.fileHandleForReading
            self.isClosed = false
            self.shouldReportTermination = true
            self.stdoutBuffer = Data()
            self.stderrBuffer = ""
            self.streamSubscriptions.removeAll(keepingCapacity: false)
        }
        pendingCalls.reset()

        do {
            let hello = try call(method: "hello", params: [:], timeout: 8.0)
            let capabilities = (hello["capabilities"] as? [String]) ?? []
            guard capabilities.contains(Self.requiredProxyStreamCapability) else {
                throw NSError(domain: "cmux.remote.daemon.rpc", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability \(Self.requiredProxyStreamCapability)",
                ])
            }
        } catch {
            stop(suppressTerminationCallback: true)
            throw error
        }
    }

    func stop() {
        stop(suppressTerminationCallback: true)
    }

    func openStream(host: String, port: Int, timeoutMs: Int = 10000) throws -> String {
        let result = try call(
            method: "proxy.open",
            params: [
                "host": host,
                "port": port,
                "timeout_ms": timeoutMs,
            ],
            timeout: 12.0
        )
        let streamID = (result["stream_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !streamID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "proxy.open missing stream_id",
            ])
        }
        return streamID
    }

    func writeStream(streamID: String, data: Data) throws {
        _ = try call(
            method: "proxy.write",
            params: [
                "stream_id": streamID,
                "data_base64": data.base64EncodedString(),
            ],
            timeout: 8.0
        )
    }

    func attachStream(
        streamID: String,
        queue: DispatchQueue,
        onEvent: @escaping (StreamEvent) -> Void
    ) throws {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "proxy.stream.subscribe requires stream_id",
            ])
        }

        stateQueue.sync {
            streamSubscriptions[trimmedStreamID] = StreamSubscription(queue: queue, handler: onEvent)
        }

        do {
            _ = try call(
                method: "proxy.stream.subscribe",
                params: ["stream_id": trimmedStreamID],
                timeout: 8.0
            )
        } catch {
            unregisterStream(streamID: trimmedStreamID)
            throw error
        }
    }

    func unregisterStream(streamID: String) {
        let trimmedStreamID = streamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStreamID.isEmpty else { return }
        _ = stateQueue.sync {
            streamSubscriptions.removeValue(forKey: trimmedStreamID)
        }
    }

    func closeStream(streamID: String) {
        unregisterStream(streamID: streamID)
        _ = try? call(
            method: "proxy.close",
            params: ["stream_id": streamID],
            timeout: 4.0
        )
    }

    private func call(method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let pendingCall = pendingCalls.register()
        let requestID = pendingCall.id

        let payload: Data
        do {
            payload = try Self.encodeJSON([
                "id": requestID,
                "method": method,
                "params": params,
            ])
        } catch {
            pendingCalls.remove(pendingCall)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "failed to encode daemon RPC request \(method): \(error.localizedDescription)",
            ])
        }

        do {
            try writeQueue.sync {
                try writePayload(payload)
            }
        } catch {
            pendingCalls.remove(pendingCall)
            throw error
        }

        let response: [String: Any]
        switch pendingCalls.wait(for: pendingCall, timeout: timeout) {
        case .timedOut:
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "daemon RPC timeout waiting for \(method) response",
            ])
        case .failure(let failure):
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 12, userInfo: [
                NSLocalizedDescriptionKey: failure,
            ])
        case .missing:
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "daemon RPC \(method) returned empty response",
            ])
        case .response(let pendingResponse):
            response = pendingResponse
        }

        let ok = (response["ok"] as? Bool) ?? false
        if ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }

        let errorObject = (response["error"] as? [String: Any]) ?? [:]
        let code = (errorObject["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "rpc_error"
        let message = (errorObject["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "daemon RPC call failed"
        throw NSError(domain: "cmux.remote.daemon.rpc", code: 14, userInfo: [
            NSLocalizedDescriptionKey: "\(method) failed (\(code)): \(message)",
        ])
    }

    private func writePayload(_ payload: Data) throws {
        let stdinHandle: FileHandle = stateQueue.sync {
            self.stdinHandle ?? FileHandle.nullDevice
        }
        if stdinHandle === FileHandle.nullDevice {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "daemon transport is not connected",
            ])
        }
        do {
            try stdinHandle.write(contentsOf: payload)
            try stdinHandle.write(contentsOf: Data([0x0A]))
        } catch {
            stop(suppressTerminationCallback: false)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "failed writing daemon RPC request: \(error.localizedDescription)",
            ])
        }
    }

    private func consumeStdoutData(_ data: Data) {
        guard !data.isEmpty else {
            signalPendingFailureLocked("daemon transport closed stdout")
            return
        }

        stdoutBuffer.append(data)
        if stdoutBuffer.count > Self.maxStdoutBufferBytes {
            stdoutBuffer.removeAll(keepingCapacity: false)
            signalPendingFailureLocked("daemon transport stdout exceeded \(Self.maxStdoutBufferBytes) bytes without message framing")
            process?.terminate()
            return
        }
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(...newlineIndex)

            if let carriageIndex = lineData.lastIndex(of: 0x0D), carriageIndex == lineData.index(before: lineData.endIndex) {
                lineData.remove(at: carriageIndex)
            }
            guard !lineData.isEmpty else { continue }

            guard let payload = try? JSONSerialization.jsonObject(with: lineData, options: []) as? [String: Any] else {
                continue
            }

            if let responseID = Self.responseID(in: payload) {
                _ = pendingCalls.resolve(id: responseID, payload: payload)
                continue
            }

            consumeEventPayload(payload)
        }
    }

    private func consumeStderrData(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        stderrBuffer.append(chunk)
        if stderrBuffer.count > 8192 {
            stderrBuffer.removeFirst(stderrBuffer.count - 8192)
        }
    }

    private func consumeEventPayload(_ payload: [String: Any]) {
        guard let eventName = (payload["event"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !eventName.isEmpty,
              let streamID = (payload["stream_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !streamID.isEmpty else {
            return
        }

        let subscription: StreamSubscription?
        let event: StreamEvent?
        switch eventName {
        case "proxy.stream.data":
            subscription = streamSubscriptions[streamID]
            event = .data(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.eof":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            event = .eof(Self.decodeBase64Data(payload["data_base64"]))

        case "proxy.stream.error":
            subscription = streamSubscriptions.removeValue(forKey: streamID)
            let detail = ((payload["error"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "stream error"
            event = .error(detail)

        default:
            return
        }

        guard let subscription, let event else { return }
        subscription.queue.async {
            subscription.handler(event)
        }
    }

    private func handleProcessTermination(_ process: Process) {
        let shouldNotify: Bool = {
            guard self.process === process else { return false }
            return !isClosed && shouldReportTermination
        }()
        let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport exited with status \(process.terminationStatus)"

        isClosed = true
        self.process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinHandle = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        streamSubscriptions.removeAll(keepingCapacity: false)
        signalPendingFailureLocked(detail)

        guard shouldNotify else { return }
        onUnexpectedTermination(detail)
    }

    private func stop(suppressTerminationCallback: Bool) {
        let captured: (Process?, FileHandle?, FileHandle?, FileHandle?, Bool, String) = stateQueue.sync {
            let detail = Self.bestErrorLine(stderr: stderrBuffer) ?? "daemon transport stopped"
            let shouldNotify = !suppressTerminationCallback && !isClosed
            shouldReportTermination = !suppressTerminationCallback
            if isClosed {
                return (nil, nil, nil, nil, false, detail)
            }

            isClosed = true
            signalPendingFailureLocked("daemon transport stopped")
            let capturedProcess = process
            let capturedStdin = stdinHandle
            let capturedStdout = stdoutHandle
            let capturedStderr = stderrHandle

            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            stderrPipe = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            streamSubscriptions.removeAll(keepingCapacity: false)
            return (capturedProcess, capturedStdin, capturedStdout, capturedStderr, shouldNotify, detail)
        }

        captured.2?.readabilityHandler = nil
        captured.3?.readabilityHandler = nil
        try? captured.1?.close()
        try? captured.2?.close()
        try? captured.3?.close()
        if let process = captured.0, process.isRunning {
            process.terminate()
        }
        if captured.4 {
            onUnexpectedTermination(captured.5)
        }
    }

    private func signalPendingFailureLocked(_ message: String) {
        pendingCalls.failAll(message)
    }

    private static func responseID(in payload: [String: Any]) -> Int? {
        if let intValue = payload["id"] as? Int {
            return intValue
        }
        if let numberValue = payload["id"] as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private static func decodeBase64Data(_ value: Any?) -> Data {
        guard let encoded = value as? String, !encoded.isEmpty else { return Data() }
        return Data(base64Encoded: encoded) ?? Data()
    }

    private static func encodeJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func daemonArguments(configuration: WorkspaceRemoteConfiguration, remotePath: String) -> [String] {
        WorkspaceRemoteSSHBatchCommandBuilder.daemonTransportArguments(
            configuration: configuration,
            remotePath: remotePath
        )
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func bestErrorLine(stderr: String) -> String? {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }
}

enum RemoteLoopbackHTTPRequestRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let canonicalLoopbackHost = "localhost"
    private static let requestLineMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "PRI"]

    static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        rewriteIfNeeded(data: data, aliasHost: aliasHost, allowIncompleteHeadersAtEOF: false)
    }

    static func rewriteIfNeeded(data: Data, aliasHost: String, allowIncompleteHeadersAtEOF: Bool) -> Data {
        let headerData: Data
        let remainder: Data

        if let headerRange = data.range(of: headerDelimiter) {
            headerData = Data(data[..<headerRange.upperBound])
            remainder = Data(data[headerRange.upperBound...])
        } else if allowIncompleteHeadersAtEOF {
            headerData = data
            remainder = Data()
        } else {
            return data
        }

        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return data }
        guard let requestLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard requestLineLooksHTTP(lines[requestLineIndex]) else { return data }

        let rewrittenRequestLine = rewriteRequestLine(lines[requestLineIndex], aliasHost: aliasHost)
        if rewrittenRequestLine != lines[requestLineIndex] {
            lines[requestLineIndex] = rewrittenRequestLine
        }

        for index in (requestLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + remainder
    }

    private static func requestLineLooksHTTP(_ requestLine: String) -> Bool {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        return requestLineMethods.contains(method)
    }

    private static func rewriteRequestLine(_ requestLine: String, aliasHost: String) -> String {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return requestLine }

        var components = URLComponents(string: String(parts[1]))
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return requestLine
        }
        components?.host = canonicalLoopbackHost
        guard let rewrittenURL = components?.string else { return requestLine }

        var rewritten = parts
        rewritten[1] = Substring(rewrittenURL)
        let leadingTrivia = requestLine.prefix { $0.isWhitespace || $0.isNewline }
        let trailingTrivia = String(requestLine.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return String(leadingTrivia) + rewritten.joined(separator: " ") + trailingTrivia
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "host":
            guard let rewrittenHost = rewriteHostValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenHost)"
        case "origin", "referer":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        default:
            return line
        }
    }

    private static func rewriteHostValue(_ value: String, aliasHost: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            guard BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
                return nil
            }
            let remainder = String(trimmed[closing...].dropFirst())
            return canonicalLoopbackHost + remainder
        }

        if let colonIndex = trimmed.lastIndex(of: ":"), !trimmed[..<colonIndex].contains(":") {
            let host = String(trimmed[..<colonIndex])
            guard BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
                return nil
            }
            return canonicalLoopbackHost + trimmed[colonIndex...]
        }

        guard BrowserInsecureHTTPSettings.normalizeHost(trimmed) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return nil
        }
        return canonicalLoopbackHost
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(aliasHost) else {
            return nil
        }
        components?.host = canonicalLoopbackHost
        return components?.string
    }
}

struct RemoteLoopbackHTTPRequestStreamRewriter {
    private static let maxHeaderBytes = 64 * 1024
    private static let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])

    private let aliasHost: String
    private var pendingHeaderBytes = Data()
    private var hasForwardedHeaders = false

    init(aliasHost: String) {
        self.aliasHost = aliasHost
    }

    mutating func rewriteNextChunk(_ data: Data, eof: Bool) -> Data {
        guard !hasForwardedHeaders else { return data }

        pendingHeaderBytes.append(data)
        if pendingHeaderBytes.count > Self.maxHeaderBytes {
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        guard pendingHeaderBytes.range(of: Self.headerDelimiter) != nil else {
            guard eof else { return Data() }
            hasForwardedHeaders = true
            let payload = pendingHeaderBytes
            pendingHeaderBytes = Data()
            return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: aliasHost,
                allowIncompleteHeadersAtEOF: true
            )
        }

        hasForwardedHeaders = true
        let payload = pendingHeaderBytes
        pendingHeaderBytes = Data()
        return RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: payload,
            aliasHost: aliasHost
        )
    }
}

enum RemoteLoopbackHTTPResponseRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let canonicalLoopbackHost = "localhost"

    static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        guard let headerRange = data.range(of: headerDelimiter) else { return data }
        let headerData = Data(data[..<headerRange.upperBound])
        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard lines[statusLineIndex].uppercased().hasPrefix("HTTP/") else { return data }

        for index in (statusLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + data[headerRange.upperBound...]
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "location", "content-location", "origin", "referer", "access-control-allow-origin":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        case "set-cookie":
            guard let rewrittenCookie = rewriteCookieValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenCookie)"
        default:
            return line
        }
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              BrowserInsecureHTTPSettings.normalizeHost(host) == BrowserInsecureHTTPSettings.normalizeHost(canonicalLoopbackHost) else {
            return nil
        }
        components?.host = aliasHost
        return components?.string
    }

    private static func rewriteCookieValue(_ value: String, aliasHost: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        var didRewrite = false
        let rewrittenParts = parts.map { part -> String in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("domain=") else { return part }
            let domainValue = String(trimmed.dropFirst("domain=".count))
            guard BrowserInsecureHTTPSettings.normalizeHost(domainValue) == BrowserInsecureHTTPSettings.normalizeHost(canonicalLoopbackHost) else {
                return part
            }
            didRewrite = true
            let leadingWhitespace = part.prefix { $0.isWhitespace }
            return "\(leadingWhitespace)Domain=\(aliasHost)"
        }

        return didRewrite ? rewrittenParts.joined(separator: ";") : nil
    }
}

private final class WorkspaceRemoteDaemonProxyTunnel {
    private final class ProxySession {
        private static let maxHandshakeBytes = 64 * 1024
        private static let remoteLoopbackProxyAliasHost = "cmux-loopback.localtest.me"

        private enum HandshakeProtocol {
            case undecided
            case socks5
            case connect
        }

        private enum SocksStage {
            case greeting
            case request
        }

        private struct SocksRequest {
            let host: String
            let port: Int
            let command: UInt8
            let consumedBytes: Int
        }

        let id = UUID()

        private let connection: NWConnection
        private let rpcClient: WorkspaceRemoteDaemonRPCClient
        private let queue: DispatchQueue
        private let onClose: (UUID) -> Void

        private var isClosed = false
        private var protocolKind: HandshakeProtocol = .undecided
        private var socksStage: SocksStage = .greeting
        private var handshakeBuffer = Data()
        private var streamID: String?
        private var localInputEOF = false
        private var rewritesLoopbackHTTPHeaders = false
        private var loopbackRequestHeaderRewriter: RemoteLoopbackHTTPRequestStreamRewriter?
        private var pendingRemoteHTTPHeaderBytes = Data()
        private var hasForwardedRemoteHTTPHeaders = false

        init(
            connection: NWConnection,
            rpcClient: WorkspaceRemoteDaemonRPCClient,
            queue: DispatchQueue,
            onClose: @escaping (UUID) -> Void
        ) {
            self.connection = connection
            self.rpcClient = rpcClient
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.close(reason: "proxy client connection failed: \(error)")
                case .cancelled:
                    self.close(reason: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()
        }

        func stop() {
            close(reason: nil)
        }

        private func receiveNext() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }

                if let data, !data.isEmpty {
                    if self.streamID == nil {
                        if self.handshakeBuffer.count + data.count > Self.maxHandshakeBytes {
                            self.close(reason: "proxy handshake exceeded \(Self.maxHandshakeBytes) bytes")
                            return
                        }
                        self.handshakeBuffer.append(data)
                        self.processHandshakeBuffer()
                    } else {
                        self.forwardToRemote(data, eof: isComplete)
                    }
                }

                if isComplete {
                    // Treat local EOF as a half-close: keep remote read loop alive so we can
                    // drain upstream response bytes (for example curl closing write-side after
                    // sending an HTTP request through SOCKS/CONNECT).
                    self.localInputEOF = true
                    if self.streamID != nil, data?.isEmpty ?? true {
                        self.forwardToRemote(Data(), eof: true, allowAfterEOF: true)
                    }
                    if self.streamID == nil {
                        self.close(reason: nil)
                    }
                    return
                }
                if let error {
                    self.close(reason: "proxy client receive error: \(error)")
                    return
                }

                self.receiveNext()
            }
        }

        private func processHandshakeBuffer() {
            guard !isClosed else { return }
            while streamID == nil {
                switch protocolKind {
                case .undecided:
                    guard let first = handshakeBuffer.first else { return }
                    protocolKind = (first == 0x05) ? .socks5 : .connect
                case .socks5:
                    if !processSocksHandshakeStep() {
                        return
                    }
                case .connect:
                    if !processConnectHandshakeStep() {
                        return
                    }
                }
            }
        }

        private func processSocksHandshakeStep() -> Bool {
            switch socksStage {
            case .greeting:
                guard handshakeBuffer.count >= 2 else { return false }
                let methodCount = Int(handshakeBuffer[1])
                let total = 2 + methodCount
                guard handshakeBuffer.count >= total else { return false }

                let methods = [UInt8](handshakeBuffer[2..<total])
                handshakeBuffer = Data(handshakeBuffer.dropFirst(total))
                socksStage = .request

                if !methods.contains(0x00) {
                    sendAndClose(Data([0x05, 0xFF]))
                    return false
                }
                sendLocal(Data([0x05, 0x00]))
                return true

            case .request:
                let request: SocksRequest
                do {
                    guard let parsed = try parseSocksRequest(from: handshakeBuffer) else { return false }
                    request = parsed
                } catch {
                    sendAndClose(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                let pending = handshakeBuffer.count > request.consumedBytes
                    ? Data(handshakeBuffer[request.consumedBytes...])
                    : Data()
                handshakeBuffer = Data()
                guard request.command == 0x01 else {
                    sendAndClose(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                openRemoteStream(
                    host: request.host,
                    port: request.port,
                    successResponse: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    failureResponse: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    pendingPayload: pending
                )
                return false
            }
        }

        private func parseSocksRequest(from data: Data) throws -> SocksRequest? {
            let bytes = [UInt8](data)
            guard bytes.count >= 4 else { return nil }
            guard bytes[0] == 0x05 else {
                throw NSError(domain: "cmux.remote.proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS version"])
            }

            let command = bytes[1]
            let addressType = bytes[3]
            var cursor = 4
            let host: String

            switch addressType {
            case 0x01:
                guard bytes.count >= cursor + 4 + 2 else { return nil }
                let octets = bytes[cursor..<(cursor + 4)].map { String($0) }
                host = octets.joined(separator: ".")
                cursor += 4

            case 0x03:
                guard bytes.count >= cursor + 1 else { return nil }
                let length = Int(bytes[cursor])
                cursor += 1
                guard bytes.count >= cursor + length + 2 else { return nil }
                let hostData = Data(bytes[cursor..<(cursor + length)])
                host = String(data: hostData, encoding: .utf8) ?? ""
                cursor += length

            case 0x04:
                guard bytes.count >= cursor + 16 + 2 else { return nil }
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { target in
                    for i in 0..<16 {
                        target[i] = bytes[cursor + i]
                    }
                }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let pointer = withUnsafePointer(to: &address) {
                    inet_ntop(AF_INET6, UnsafeRawPointer($0), &text, socklen_t(INET6_ADDRSTRLEN))
                }
                host = pointer != nil ? String(cString: text) : ""
                cursor += 16

            default:
                throw NSError(domain: "cmux.remote.proxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS address type"])
            }

            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "cmux.remote.proxy", code: 3, userInfo: [NSLocalizedDescriptionKey: "empty SOCKS host"])
            }
            guard bytes.count >= cursor + 2 else { return nil }
            let port = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            cursor += 2

            guard port > 0 && port <= 65535 else {
                throw NSError(domain: "cmux.remote.proxy", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS port"])
            }

            return SocksRequest(host: host, port: port, command: command, consumedBytes: cursor)
        }

        private func processConnectHandshakeStep() -> Bool {
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let headerRange = handshakeBuffer.range(of: marker) else { return false }

            let headerData = Data(handshakeBuffer[..<headerRange.upperBound])
            let pending = headerRange.upperBound < handshakeBuffer.count
                ? Data(handshakeBuffer[headerRange.upperBound...])
                : Data()
            handshakeBuffer = Data()
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            guard let (host, port) = Self.parseConnectAuthority(parts[1]) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            openRemoteStream(
                host: host,
                port: port,
                successResponse: Self.httpResponse(status: "200 Connection Established", closeAfterResponse: false),
                failureResponse: Self.httpResponse(status: "502 Bad Gateway", closeAfterResponse: true),
                pendingPayload: pending
            )
            return false
        }

        private func openRemoteStream(
            host: String,
            port: Int,
            successResponse: Data,
            failureResponse: Data,
            pendingPayload: Data
        ) {
            guard !isClosed else { return }
            do {
                rewritesLoopbackHTTPHeaders =
                    BrowserInsecureHTTPSettings.normalizeHost(host)
                    == BrowserInsecureHTTPSettings.normalizeHost(Self.remoteLoopbackProxyAliasHost)
                loopbackRequestHeaderRewriter = rewritesLoopbackHTTPHeaders
                    ? RemoteLoopbackHTTPRequestStreamRewriter(aliasHost: Self.remoteLoopbackProxyAliasHost)
                    : nil
                pendingRemoteHTTPHeaderBytes = Data()
                hasForwardedRemoteHTTPHeaders = false
                let targetHost = Self.normalizedProxyTargetHost(host)
                let streamID = try rpcClient.openStream(host: targetHost, port: port)
                self.streamID = streamID
                try rpcClient.attachStream(streamID: streamID, queue: queue) { [weak self] event in
                    self?.handleRemoteStreamEvent(streamID: streamID, event: event)
                }
                connection.send(content: successResponse, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if !pendingPayload.isEmpty {
                        self.forwardToRemote(pendingPayload, allowAfterEOF: true)
                    }
                })
            } catch {
                sendAndClose(failureResponse)
            }
        }

        private func forwardToRemote(_ data: Data, eof: Bool = false, allowAfterEOF: Bool = false) {
            guard !isClosed else { return }
            guard !localInputEOF || allowAfterEOF else { return }
            guard let streamID else { return }
            do {
                let outgoingData: Data
                if rewritesLoopbackHTTPHeaders {
                    outgoingData = loopbackRequestHeaderRewriter?.rewriteNextChunk(data, eof: eof) ?? data
                } else {
                    outgoingData = data
                }
                guard !outgoingData.isEmpty else { return }
                try rpcClient.writeStream(streamID: streamID, data: outgoingData)
            } catch {
                close(reason: "proxy.write failed: \(error.localizedDescription)")
            }
        }

        private func handleRemoteStreamEvent(
            streamID: String,
            event: WorkspaceRemoteDaemonRPCClient.StreamEvent
        ) {
            guard !isClosed else { return }
            guard self.streamID == streamID else { return }

            switch event {
            case .data(let data):
                forwardRemotePayloadToLocal(data, eof: false)

            case .eof(let data):
                forwardRemotePayloadToLocal(data, eof: true)

            case .error(let detail):
                close(reason: "proxy.stream failed: \(detail)")
            }
        }

        private func forwardRemotePayloadToLocal(_ data: Data, eof: Bool) {
            let localData = rewriteRemoteResponseIfNeeded(data, eof: eof)
            if !localData.isEmpty {
                connection.send(content: localData, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if eof {
                        self.close(reason: nil)
                    }
                })
                return
            }

            if eof {
                close(reason: nil)
            }
        }

        private func rewriteRemoteResponseIfNeeded(_ data: Data, eof: Bool) -> Data {
            guard rewritesLoopbackHTTPHeaders else { return data }
            guard !data.isEmpty else { return data }
            guard !hasForwardedRemoteHTTPHeaders else { return data }

            pendingRemoteHTTPHeaderBytes.append(data)
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard pendingRemoteHTTPHeaderBytes.range(of: marker) != nil else {
                guard eof else { return Data() }
                hasForwardedRemoteHTTPHeaders = true
                let payload = pendingRemoteHTTPHeaderBytes
                pendingRemoteHTTPHeaderBytes = Data()
                return payload
            }

            hasForwardedRemoteHTTPHeaders = true
            let payload = pendingRemoteHTTPHeaderBytes
            pendingRemoteHTTPHeaderBytes = Data()
            return RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: Self.remoteLoopbackProxyAliasHost
            )
        }

        private func close(reason: String?) {
            guard !isClosed else { return }
            isClosed = true

            let streamID = self.streamID
            self.streamID = nil

            if let streamID {
                rpcClient.closeStream(streamID: streamID)
            }
            connection.cancel()
            onClose(id)
        }

        private func sendLocal(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.close(reason: "proxy client send error: \(error)")
                }
            })
        }

        private func sendAndClose(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.close(reason: nil)
            })
        }

        private static func parseConnectAuthority(_ authority: String) -> (host: String, port: Int)? {
            let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("[") {
                guard let closing = trimmed.firstIndex(of: "]") else { return nil }
                let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
                let portStart = trimmed.index(after: closing)
                guard portStart < trimmed.endIndex, trimmed[portStart] == ":" else { return nil }
                let portString = String(trimmed[trimmed.index(after: portStart)...])
                guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
                return (host, port)
            }

            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            let host = String(trimmed[..<colon])
            let portString = String(trimmed[trimmed.index(after: colon)...])
            guard !host.isEmpty else { return nil }
            guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
            return (host, port)
        }

        private static func normalizedProxyTargetHost(_ host: String) -> String {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            // BrowserPanel rewrites loopback URLs to this alias so proxy routing works.
            // Resolve it back to true loopback before dialing from the remote daemon.
            if normalized == remoteLoopbackProxyAliasHost {
                return "127.0.0.1"
            }
            return host
        }

        private static func httpResponse(status: String, closeAfterResponse: Bool = true) -> Data {
            var text = "HTTP/1.1 \(status)\r\nProxy-Agent: cmux\r\n"
            if closeAfterResponse {
                text += "Connection: close\r\n"
            }
            text += "\r\n"
            return Data(text.utf8)
        }
    }

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let localPort: Int
    private let onFatalError: (String) -> Void
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-tunnel.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var rpcClient: WorkspaceRemoteDaemonRPCClient?
    private var sessions: [UUID: ProxySession] = [:]
    private var isStopped = false

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.localPort = localPort
        self.onFatalError = onFatalError
    }

    func start() throws {
        var capturedError: Error?
        queue.sync {
            guard !isStopped else {
                capturedError = NSError(domain: "cmux.remote.proxy", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "proxy tunnel already stopped",
                ])
                return
            }
            do {
                let client = WorkspaceRemoteDaemonRPCClient(
                    configuration: configuration,
                    remotePath: remotePath
                ) { [weak self] detail in
                    self?.queue.async {
                        self?.failLocked("Remote daemon transport failed: \(detail)")
                    }
                }
                try client.start()

                let listener = try Self.makeLoopbackListener(port: localPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.queue.async {
                        self?.acceptConnectionLocked(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        self?.handleListenerStateLocked(state)
                    }
                }

                self.rpcClient = client
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                capturedError = error
                stopLocked(notify: false)
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    func stop() {
        queue.sync {
            stopLocked(notify: false)
        }
    }

    private func handleListenerStateLocked(_ state: NWListener.State) {
        guard !isStopped else { return }
        switch state {
        case .failed(let error):
            failLocked("Local proxy listener failed: \(error)")
        default:
            break
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        guard let rpcClient else {
            connection.cancel()
            return
        }

        let session = ProxySession(
            connection: connection,
            rpcClient: rpcClient,
            queue: queue
        ) { [weak self] id in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }
        sessions[session.id] = session
        session.start()
    }

    private func failLocked(_ detail: String) {
        guard !isStopped else { return }
        stopLocked(notify: false)
        onFatalError(detail)
    }

    private func stopLocked(notify: Bool) {
        guard !isStopped else { return }
        isStopped = true

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        let activeSessions = sessions.values
        sessions.removeAll()
        for session in activeSessions {
            session.stop()
        }

        rpcClient?.stop()
        rpcClient = nil
    }

    private static func makeLoopbackListener(port: Int) throws -> NWListener {
        guard let localPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "cmux.remote.proxy", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "invalid local proxy port \(port)",
            ])
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: localPort)
        return try NWListener(using: parameters)
    }
}

private final class WorkspaceRemoteProxyBroker {
    enum Update {
        case connecting
        case ready(BrowserProxyEndpoint)
        case error(String)
    }

    final class Lease {
        private let key: String
        private let subscriberID: UUID
        private weak var broker: WorkspaceRemoteProxyBroker?
        private var isReleased = false

        fileprivate init(key: String, subscriberID: UUID, broker: WorkspaceRemoteProxyBroker) {
            self.key = key
            self.subscriberID = subscriberID
            self.broker = broker
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            broker?.release(key: key, subscriberID: subscriberID)
        }

        deinit {
            release()
        }
    }

    private final class Entry {
        let configuration: WorkspaceRemoteConfiguration
        var remotePath: String
        var tunnel: WorkspaceRemoteDaemonProxyTunnel?
        var endpoint: BrowserProxyEndpoint?
        var restartWorkItem: DispatchWorkItem?
        var restartRetryCount = 0
        var subscribers: [UUID: (Update) -> Void] = [:]

        init(configuration: WorkspaceRemoteConfiguration, remotePath: String) {
            self.configuration = configuration
            self.remotePath = remotePath
        }
    }

    static let shared = WorkspaceRemoteProxyBroker()

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.proxy-broker", qos: .utility)
    private var entries: [String: Entry] = [:]

    func acquire(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        onUpdate: @escaping (Update) -> Void
    ) -> Lease {
        queue.sync {
            let key = Self.transportKey(for: configuration)
            let subscriberID = UUID()
            let entry: Entry
            if let existing = entries[key] {
                entry = existing
                if existing.remotePath != remotePath {
                    existing.remotePath = remotePath
                    existing.restartRetryCount = 0
                    if existing.tunnel != nil {
                        stopEntryRuntimeLocked(existing)
                        notifyLocked(existing, update: .connecting)
                    }
                }
            } else {
                entry = Entry(configuration: configuration, remotePath: remotePath)
                entries[key] = entry
            }

            entry.subscribers[subscriberID] = onUpdate
            if let endpoint = entry.endpoint {
                onUpdate(.ready(endpoint))
            } else {
                onUpdate(.connecting)
            }

            if entry.tunnel == nil, entry.restartWorkItem == nil {
                startEntryLocked(key: key, entry: entry)
            }

            return Lease(key: key, subscriberID: subscriberID, broker: self)
        }
    }

    private func release(key: String, subscriberID: UUID) {
        queue.async { [weak self] in
            guard let self, let entry = self.entries[key] else { return }
            entry.subscribers.removeValue(forKey: subscriberID)
            guard entry.subscribers.isEmpty else { return }
            self.teardownEntryLocked(key: key, entry: entry)
        }
    }

    private func startEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil

        let localPort: Int
        if let forcedLocalPort = entry.configuration.localProxyPort {
            // Internal deterministic test hook used by docker regressions to force bind conflicts.
            localPort = forcedLocalPort
        } else {
            let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
            guard let allocatedPort = Self.allocateLoopbackPort() else {
                notifyLocked(
                    entry,
                    update: .error("Failed to allocate local proxy port\(Self.retrySuffix(delay: retryDelay))")
                )
                scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
                return
            }
            localPort = allocatedPort
        }

        do {
            let tunnel = WorkspaceRemoteDaemonProxyTunnel(
                configuration: entry.configuration,
                remotePath: entry.remotePath,
                localPort: localPort
            ) { [weak self] detail in
                self?.queue.async {
                    self?.handleTunnelFailureLocked(key: key, detail: detail)
                }
            }
            try tunnel.start()
            entry.tunnel = tunnel
            let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: localPort)
            entry.endpoint = endpoint
            entry.restartRetryCount = 0
            notifyLocked(entry, update: .ready(endpoint))
        } catch {
            stopEntryRuntimeLocked(entry)
            let detail = "Failed to start local daemon proxy: \(error.localizedDescription)"
            let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
            notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: retryDelay))"))
            scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
        }
    }

    private func handleTunnelFailureLocked(key: String, detail: String) {
        guard let entry = entries[key], entry.tunnel != nil else { return }
        stopEntryRuntimeLocked(entry)
        let retryDelay = Self.retryDelay(baseDelay: 3.0, retry: entry.restartRetryCount + 1)
        notifyLocked(entry, update: .error("\(detail)\(Self.retrySuffix(delay: retryDelay))"))
        scheduleRestartLocked(key: key, entry: entry, baseDelay: 3.0)
    }

    private func scheduleRestartLocked(key: String, entry: Entry, baseDelay: TimeInterval) {
        guard !entry.subscribers.isEmpty else {
            teardownEntryLocked(key: key, entry: entry)
            return
        }
        guard entry.restartWorkItem == nil else { return }
        entry.restartRetryCount += 1
        let retryDelay = Self.retryDelay(baseDelay: baseDelay, retry: entry.restartRetryCount)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentEntry = self.entries[key] else { return }
            currentEntry.restartWorkItem = nil
            guard !currentEntry.subscribers.isEmpty else {
                self.teardownEntryLocked(key: key, entry: currentEntry)
                return
            }
            self.notifyLocked(currentEntry, update: .connecting)
            self.startEntryLocked(key: key, entry: currentEntry)
        }

        entry.restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
    }

    private func teardownEntryLocked(key: String, entry: Entry) {
        entry.restartWorkItem?.cancel()
        entry.restartWorkItem = nil
        stopEntryRuntimeLocked(entry)
        entries.removeValue(forKey: key)
    }

    private func stopEntryRuntimeLocked(_ entry: Entry) {
        entry.tunnel?.stop()
        entry.tunnel = nil
        entry.endpoint = nil
    }

    private func notifyLocked(_ entry: Entry, update: Update) {
        for callback in entry.subscribers.values {
            callback(update)
        }
    }

    private static func transportKey(for configuration: WorkspaceRemoteConfiguration) -> String {
        configuration.proxyBrokerTransportKey
    }

    private static func allocateLoopbackPort() -> Int? {
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(fd, sockaddrPtr, &len)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 && port <= 65535 {
                return port
            }
        }
        return nil
    }

    private static func retrySuffix(delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry in \(seconds)s)"
    }

    private static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }
}

private final class WorkspaceRemoteCLIRelayServer {
    private final class Session {
        private enum Phase {
            case awaitingAuth
            case awaitingCommand
            case forwarding
            case closed
        }

        private let connection: NWConnection
        private let localSocketPath: String
        private let relayID: String
        private let relayToken: Data
        private let queue: DispatchQueue
        private let onClose: () -> Void
        private let challengeProtocol = "cmux-relay-auth"
        private let challengeVersion = 1
        private let minimumFailureDelay: TimeInterval = 0.05
        private let maximumFrameBytes = 16 * 1024

        private var buffer = Data()
        private var phase: Phase = .awaitingAuth
        private var challengeNonce = ""
        private var challengeSentAt = Date()
        private var isClosed = false

        init(
            connection: NWConnection,
            localSocketPath: String,
            relayID: String,
            relayToken: Data,
            queue: DispatchQueue,
            onClose: @escaping () -> Void
        ) {
            self.connection = connection
            self.localSocketPath = localSocketPath
            self.relayID = relayID
            self.relayToken = relayToken
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    self?.handleState(state)
                }
            }
            connection.start(queue: queue)
        }

        func stop() {
            close()
        }

        private func handleState(_ state: NWConnection.State) {
            guard !isClosed else { return }
            switch state {
            case .ready:
                sendChallenge()
                receive()
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }

        private func sendChallenge() {
            challengeSentAt = Date()
            challengeNonce = Self.randomHex(byteCount: 16)
            let challenge: [String: Any] = [
                "protocol": challengeProtocol,
                "version": challengeVersion,
                "relay_id": relayID,
                "nonce": challengeNonce,
            ]
            sendJSONLine(challenge) { _ in }
        }

        private func receive() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumFrameBytes) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.queue.async {
                    if error != nil {
                        self.close()
                        return
                    }
                    if let data, !data.isEmpty {
                        self.buffer.append(data)
                        if self.buffer.count > self.maximumFrameBytes {
                            self.sendFailureAndClose()
                            return
                        }
                        self.processBufferedLines()
                    }
                    if isComplete {
                        self.close()
                        return
                    }
                    if !self.isClosed {
                        self.receive()
                    }
                }
            }
        }

        private func processBufferedLines() {
            while let newlineIndex = buffer.firstIndex(of: 0x0A), !isClosed {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                switch phase {
                case .awaitingAuth:
                    handleAuthLine(line)
                case .awaitingCommand:
                    handleCommandLine(Data(lineData) + Data([0x0A]))
                case .forwarding, .closed:
                    return
                }
            }
        }

        private func handleAuthLine(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let receivedRelayID = object["relay_id"] as? String,
                  receivedRelayID == relayID,
                  let macHex = object["mac"] as? String,
                  let receivedMAC = Self.hexData(from: macHex)
            else {
                sendFailureAndClose()
                return
            }

            let message = Self.authMessage(relayID: relayID, nonce: challengeNonce, version: challengeVersion)
            let expectedMAC = Self.authMAC(token: relayToken, message: message)
            guard Self.constantTimeEqual(receivedMAC, expectedMAC) else {
                sendFailureAndClose()
                return
            }

            phase = .awaitingCommand
            sendJSONLine(["ok": true]) { [weak self] _ in
                self?.queue.async {
                    self?.processBufferedLines()
                }
            }
        }

        private func handleCommandLine(_ commandLine: Data) {
            guard !commandLine.isEmpty else {
                sendFailureAndClose()
                return
            }
            phase = .forwarding
            DispatchQueue.global(qos: .utility).async { [localSocketPath, commandLine, queue] in
                let result = Result { try Self.roundTripUnixSocket(socketPath: localSocketPath, request: commandLine) }
                queue.async { [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let response):
                        self.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                            self?.queue.async {
                                self?.close()
                            }
                        })
                    case .failure:
                        self.sendFailureAndClose()
                    }
                }
            }
        }

        private func sendFailureAndClose() {
            let elapsed = Date().timeIntervalSince(challengeSentAt)
            let delay = max(0, minimumFailureDelay - elapsed)
            phase = .closed
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendJSONLine(["ok": false]) { [weak self] _ in
                    self?.queue.async {
                        self?.close()
                    }
                }
            }
        }

        private func sendJSONLine(_ object: [String: Any], completion: @escaping (NWError?) -> Void) {
            guard !isClosed else {
                completion(nil)
                return
            }
            guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
                completion(nil)
                return
            }
            connection.send(content: payload + Data([0x0A]), completion: .contentProcessed(completion))
        }

        private func close() {
            guard !isClosed else { return }
            isClosed = true
            phase = .closed
            connection.stateUpdateHandler = nil
            connection.cancel()
            onClose()
        }

        private static func authMessage(relayID: String, nonce: String, version: Int) -> Data {
            Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)".utf8)
        }

        private static func authMAC(token: Data, message: Data) -> Data {
            let key = SymmetricKey(data: token)
            let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
            return Data(code)
        }

        private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
            guard lhs.count == rhs.count else { return false }
            var diff: UInt8 = 0
            for index in lhs.indices {
                diff |= lhs[index] ^ rhs[index]
            }
            return diff == 0
        }

        fileprivate static func hexData(from string: String) -> Data? {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count.isMultiple(of: 2), !normalized.isEmpty else { return nil }
            var data = Data(capacity: normalized.count / 2)
            var cursor = normalized.startIndex
            while cursor < normalized.endIndex {
                let next = normalized.index(cursor, offsetBy: 2)
                guard let byte = UInt8(normalized[cursor..<next], radix: 16) else { return nil }
                data.append(byte)
                cursor = next
            }
            return data
        }

        private static func randomHex(byteCount: Int) -> String {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        private static func roundTripUnixSocket(socketPath: String, request: Data) throws -> Data {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw NSError(domain: "cmux.remote.relay", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "failed to create local relay socket",
                ])
            }
            defer { Darwin.close(fd) }

            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            withUnsafePointer(to: &timeout) { pointer in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8CString)
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw NSError(domain: "cmux.remote.relay", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "local relay socket path is too long",
                ])
            }
            let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            withUnsafeMutableBytes(of: &address) { rawBuffer in
                let destination = rawBuffer.baseAddress!.advanced(by: sunPathOffset)
                pathBytes.withUnsafeBytes { pathBuffer in
                    destination.copyMemory(from: pathBuffer.baseAddress!, byteCount: pathBytes.count)
                }
            }

            let addressLength = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
            let connectResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, addressLength)
                }
            }
            guard connectResult == 0 else {
                throw NSError(domain: "cmux.remote.relay", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "failed to connect to local cmux socket",
                ])
            }

            try request.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var pointer = baseAddress
                while bytesRemaining > 0 {
                    let written = Darwin.write(fd, pointer, bytesRemaining)
                    if written <= 0 {
                        throw NSError(domain: "cmux.remote.relay", code: 4, userInfo: [
                            NSLocalizedDescriptionKey: "failed to write relay request",
                        ])
                    }
                    bytesRemaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
            _ = shutdown(fd, SHUT_WR)

            var response = Data()
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &scratch, scratch.count)
                if count > 0 {
                    response.append(scratch, count: count)
                    continue
                }
                if count == 0 {
                    break
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if !response.isEmpty {
                        break
                    }
                    throw NSError(domain: "cmux.remote.relay", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "timed out waiting for local cmux response",
                    ])
                }
                throw NSError(domain: "cmux.remote.relay", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "failed to read local cmux response",
                ])
            }
            return response
        }
    }

    private let localSocketPath: String
    private let relayID: String
    private let relayToken: Data
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.cli-relay.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]
    private var isStopped = false
    private(set) var localPort: Int?

    init(localSocketPath: String, relayID: String, relayTokenHex: String) throws {
        guard let relayToken = Session.hexData(from: relayTokenHex), !relayToken.isEmpty else {
            throw NSError(domain: "cmux.remote.relay", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "invalid relay token",
            ])
        }
        self.localSocketPath = localSocketPath
        self.relayID = relayID
        self.relayToken = relayToken
    }

    func start() throws -> Int {
        if let existingPort = queue.sync(execute: { localPort }) {
            return existingPort
        }

        let listener = try Self.makeLoopbackListener()
        let readySemaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var capturedError: Error?
        var boundPort: Int?

        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.acceptConnectionLocked(connection)
            }
        }
        listener.stateUpdateHandler = { listenerState in
            switch listenerState {
            case .ready:
                stateLock.lock()
                boundPort = listener.port.map { Int($0.rawValue) }
                stateLock.unlock()
                readySemaphore.signal()
            case .failed(let error):
                stateLock.lock()
                capturedError = error
                stateLock.unlock()
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        let waitResult = readySemaphore.wait(timeout: .now() + 5.0)
        stateLock.lock()
        let startupError = capturedError
        let startupPort = boundPort
        stateLock.unlock()

        if waitResult != .success {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw NSError(domain: "cmux.remote.relay", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for local relay listener",
            ])
        }
        if let startupError {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw startupError
        }
        guard let startupPort, startupPort > 0 else {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw NSError(domain: "cmux.remote.relay", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "failed to bind local relay listener",
            ])
        }

        return queue.sync {
            if let localPort {
                listener.newConnectionHandler = nil
                listener.stateUpdateHandler = nil
                listener.cancel()
                return localPort
            }
            self.listener = listener
            self.localPort = startupPort
            return startupPort
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            listener?.newConnectionHandler = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            localPort = nil
            let activeSessions = sessions.values
            sessions.removeAll()
            for session in activeSessions {
                session.stop()
            }
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        let sessionID = UUID()
        let session = Session(
            connection: connection,
            localSocketPath: localSocketPath,
            relayID: relayID,
            relayToken: relayToken,
            queue: queue
        ) { [weak self] in
            self?.sessions.removeValue(forKey: sessionID)
        }
        sessions[sessionID] = session
        session.start()
    }

    private static func makeLoopbackListener() throws -> NWListener {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        return try NWListener(using: parameters)
    }
}

final class WorkspaceRemoteSessionController {
    enum PortScanKickReason: String {
        case command
        case refresh

        var burstOffsets: [Double] {
            switch self {
            case .command:
                return [0.5, 1.5, 3.0, 5.0, 7.5, 10.0]
            case .refresh:
                return [0.0]
            }
        }

        func merged(with other: Self) -> Self {
            switch (self, other) {
            case (.command, _), (_, .command):
                return .command
            case (.refresh, .refresh):
                return .refresh
            }
        }
    }

    private struct RetrySchedule {
        let retry: Int
        let delay: TimeInterval
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct RemotePlatform {
        let goOS: String
        let goArch: String
    }

    private struct RemoteBootstrapState {
        let platform: RemotePlatform
        let binaryExists: Bool
    }

    private struct DaemonHello {
        let name: String
        let version: String
        let capabilities: [String]
        let remotePath: String
    }

    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.\(UUID().uuidString)", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private weak var workspace: Workspace?
    private let configuration: WorkspaceRemoteConfiguration
    private let controllerID: UUID

    private enum RemotePortPollingMode {
        case hostWide
        case hostWideDelta
        case ttyScoped

        var initialDelay: TimeInterval {
            switch self {
            case .hostWide:
                return 0.5
            case .hostWideDelta:
                return 0.5
            case .ttyScoped:
                return 1.0
            }
        }

        var repeatInterval: TimeInterval {
            switch self {
            case .hostWide:
                return 2.0
            case .hostWideDelta:
                return 5.0
            case .ttyScoped:
                return 5.0
            }
        }
    }

    private var isStopping = false
    private var proxyLease: WorkspaceRemoteProxyBroker.Lease?
    private var proxyEndpoint: BrowserProxyEndpoint?
    private var daemonReady = false
    private var daemonBootstrapVersion: String?
    private var daemonRemotePath: String?
    private var reverseRelayProcess: Process?
    private var reverseRelayControlMasterForwardSpec: String?
    private var cliRelayServer: WorkspaceRemoteCLIRelayServer?
    private var remotePortScanTTYNames: [UUID: String] = [:]
    private var remoteScannedPortsByPanel: [UUID: [Int]] = [:]
    private var remotePortScanBurstActive = false
    private var remotePortScanActiveReason: PortScanKickReason?
    private var remotePortScanPendingReason: PortScanKickReason?
    private var remotePortScanGeneration: UInt64 = 0
    private var remotePortScanCoalesceWorkItem: DispatchWorkItem?
    private var remotePortPollTimer: DispatchSourceTimer?
    private var remotePortPollMode: RemotePortPollingMode?
    private var polledRemotePorts: [Int] = []
    private var remotePortPollBaselinePorts: Set<Int>?
    private var keepPolledRemotePortsUntilTTYScan = false
    private var bootstrapRemoteTTYResolved = false
    private var bootstrapRemoteTTYRetryWorkItem: DispatchWorkItem?
    private var bootstrapRemoteTTYFetchInFlight = false
    private var bootstrapRemoteTTYRetryCount = 0
    private var reverseRelayStderrPipe: Pipe?
    private var reverseRelayRestartWorkItem: DispatchWorkItem?
    private var reverseRelayStderrBuffer = ""
    private var reconnectRetryCount = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var heartbeatCount: Int = 0
    private var connectionAttemptStartedAt: Date?

    private static let reverseRelayStartupGracePeriod: TimeInterval = 0.5

    init(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, controllerID: UUID) {
        self.workspace = workspace
        self.configuration = configuration
        self.controllerID = controllerID
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() {
        debugLog("remote.session.start \(debugConfigSummary())")
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopping else { return }
            self.beginConnectionAttemptLocked()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopAllLocked()
            return
        }
        queue.async { [self] in
            stopAllLocked()
        }
    }

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.failure(RemoteDropUploadError.unavailable))
                }
                return
            }

            do {
                try operation.throwIfCancelled()
                let remotePaths = try self.uploadDroppedFilesLocked(fileURLs, operation: operation)
                try operation.throwIfCancelled()
                DispatchQueue.main.async { [weak self] in
                    if operation.isCancelled {
                        guard let self else {
                            completion(.failure(TerminalImageTransferExecutionError.cancelled))
                            return
                        }
                        self.queue.async { [weak self] in
                            self?.cleanupUploadedRemotePaths(remotePaths)
                            DispatchQueue.main.async {
                                completion(.failure(TerminalImageTransferExecutionError.cancelled))
                            }
                        }
                    } else {
                        completion(.success(remotePaths))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        uploadDroppedFiles(
            fileURLs,
            operation: TerminalImageTransferOperation(),
            completion: completion
        )
    }

    private func stopAllLocked() {
        debugLog("remote.session.stop \(debugConfigSummary())")
        isStopping = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectRetryCount = 0
        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        remotePortScanCoalesceWorkItem?.cancel()
        remotePortScanCoalesceWorkItem = nil
        stopReverseRelayLocked()
        remotePortScanGeneration &+= 1
        remotePortScanBurstActive = false
        remotePortScanActiveReason = nil
        remotePortScanPendingReason = nil
        remotePortScanTTYNames.removeAll()
        remoteScannedPortsByPanel.removeAll()
        stopRemotePortPollingLocked()
        polledRemotePorts = []
        remotePortPollBaselinePorts = nil
        keepPolledRemotePortsUntilTTYScan = false
        bootstrapRemoteTTYResolved = false
        bootstrapRemoteTTYRetryWorkItem?.cancel()
        bootstrapRemoteTTYRetryWorkItem = nil
        bootstrapRemoteTTYFetchInFlight = false
        bootstrapRemoteTTYRetryCount = 0

        proxyLease?.release()
        proxyLease = nil
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
        publishPortsSnapshotLocked()
    }

    private func beginConnectionAttemptLocked() {
        guard !isStopping else { return }

        Self.killOrphanedRemoteSSHProcesses(
            destination: configuration.destination,
            relayPort: configuration.relayPort
        )
        connectionAttemptStartedAt = Date()
        debugLog("remote.session.connect.begin retry=\(reconnectRetryCount) \(debugConfigSummary())")
        reconnectWorkItem = nil
        bootstrapRemoteTTYRetryWorkItem?.cancel()
        bootstrapRemoteTTYRetryWorkItem = nil
        bootstrapRemoteTTYFetchInFlight = false
        if remotePortScanTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = false
            bootstrapRemoteTTYRetryCount = 0
        }
        let connectDetail: String
        let bootstrapDetail: String
        if reconnectRetryCount > 0 {
            connectDetail = "Reconnecting to \(configuration.displayTarget) (retry \(reconnectRetryCount))"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget) (retry \(reconnectRetryCount))"
        } else {
            connectDetail = "Connecting to \(configuration.displayTarget)"
            bootstrapDetail = "Bootstrapping remote daemon on \(configuration.displayTarget)"
        }
        publishState(.connecting, detail: connectDetail)
        publishDaemonStatus(.bootstrapping, detail: bootstrapDetail)
        do {
            let hello = try bootstrapDaemonLocked()
            guard hello.capabilities.contains(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability) else {
                throw NSError(domain: "cmux.remote.daemon", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon missing required capability \(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability)",
                ])
            }
            daemonReady = true
            daemonBootstrapVersion = hello.version
            daemonRemotePath = hello.remotePath
            publishDaemonStatus(
                .ready,
                detail: "Remote daemon ready",
                version: hello.version,
                name: hello.name,
                capabilities: hello.capabilities,
                remotePath: hello.remotePath
            )
            recordHeartbeatActivityLocked()
            startReverseRelayLocked(remotePath: hello.remotePath)
            requestBootstrapRemoteTTYIfNeededLocked()
            startProxyLocked()
        } catch {
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon bootstrap failed: \(error.localizedDescription)\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
        }
    }

    private func startProxyLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard proxyLease == nil else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let retrySchedule = scheduleReconnectLocked(baseDelay: 4.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            let detail = "Remote daemon did not provide a valid remote path\(retrySuffix)"
            publishDaemonStatus(.error, detail: detail)
            publishState(.error, detail: detail)
            return
        }

        let lease = WorkspaceRemoteProxyBroker.shared.acquire(
            configuration: configuration,
            remotePath: remotePath
        ) { [weak self] update in
            self?.queue.async {
                self?.handleProxyBrokerUpdateLocked(update)
            }
        }
        proxyLease = lease
    }

    private func startReverseRelayLocked(remotePath: String) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0,
              let relayID = configuration.relayID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayID.isEmpty,
              let relayToken = configuration.relayToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayToken.isEmpty,
              let localSocketPath = configuration.localSocketPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !localSocketPath.isEmpty else {
            return
        }
        guard reverseRelayProcess == nil else { return }
        guard reverseRelayControlMasterForwardSpec == nil else { return }

        reverseRelayRestartWorkItem?.cancel()
        reverseRelayRestartWorkItem = nil
        var relayServer: WorkspaceRemoteCLIRelayServer?
        do {
            let server = try ensureCLIRelayServerLocked(
                localSocketPath: localSocketPath,
                relayID: relayID,
                relayToken: relayToken
            )
            relayServer = server
            let localRelayPort = try server.start()
            Self.killOrphanedRemoteSSHProcesses(
                destination: configuration.destination,
                relayPort: relayPort
            )
            let forwardSpec = "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)"

            if startReverseRelayViaControlMasterLocked(forwardSpec: forwardSpec) {
                cliRelayServer = relayServer
                reverseRelayStderrBuffer = ""
                do {
                    try installRemoteRelayMetadataLocked(
                        remotePath: remotePath,
                        relayPort: relayPort,
                        relayID: relayID,
                        relayToken: relayToken
                    )
                } catch {
                    debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                    stopReverseRelayLocked()
                    scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                    return
                }
                recordHeartbeatActivityLocked()
                debugLog(
                    "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                    "target=\(configuration.displayTarget) controlMaster=1"
                )
                return
            }

            let process = Process()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = reverseRelayArguments(relayPort: relayPort, localRelayPort: localRelayPort)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe

            process.terminationHandler = { [weak self] terminated in
                self?.queue.async {
                    self?.handleReverseRelayTerminationLocked(process: terminated)
                }
            }

            try process.run()
            if let startupFailure = Self.reverseRelayStartupFailureDetail(
                process: process,
                stderrPipe: stderrPipe
            ) {
                let retryDelay = 2.0
                let retrySeconds = max(1, Int(retryDelay.rounded()))
                debugLog(
                    "remote.relay.startFailed relayPort=\(relayPort) " +
                    "error=\(startupFailure)"
                )
                relayServer?.stop()
                publishDaemonStatus(
                    .error,
                    detail: "Remote SSH relay unavailable: \(startupFailure) (retry in \(retrySeconds)s)"
                )
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: retryDelay)
                return
            }
            installReverseRelayStderrHandlerLocked(stderrPipe)
            reverseRelayProcess = process
            cliRelayServer = relayServer
            reverseRelayStderrPipe = stderrPipe
            reverseRelayStderrBuffer = ""
            do {
                try installRemoteRelayMetadataLocked(
                    remotePath: remotePath,
                    relayPort: relayPort,
                    relayID: relayID,
                    relayToken: relayToken
                )
            } catch {
                debugLog("remote.relay.metadata.error \(error.localizedDescription)")
                stopReverseRelayLocked()
                scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
                return
            }
            recordHeartbeatActivityLocked()
            debugLog(
                "remote.relay.start relayPort=\(relayPort) localRelayPort=\(localRelayPort) " +
                "target=\(configuration.displayTarget) controlMaster=0"
            )
        } catch {
            debugLog(
                "remote.relay.startFailed relayPort=\(relayPort) " +
                "error=\(error.localizedDescription)"
            )
            relayServer?.stop()
            cliRelayServer = nil
            scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
        }
    }

    private func installReverseRelayStderrHandlerLocked(_ stderrPipe: Pipe) {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                guard let self else { return }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    self.reverseRelayStderrBuffer.append(chunk)
                    if self.reverseRelayStderrBuffer.count > 8192 {
                        self.reverseRelayStderrBuffer.removeFirst(self.reverseRelayStderrBuffer.count - 8192)
                    }
                }
            }
        }
    }

    private func handleReverseRelayTerminationLocked(process: Process) {
        guard reverseRelayProcess === process else { return }
        let stderrDetail = Self.bestErrorLine(stderr: reverseRelayStderrBuffer)
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        reverseRelayProcess = nil
        reverseRelayStderrPipe = nil

        guard !isStopping else { return }
        guard let remotePath = daemonRemotePath,
              !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let detail = stderrDetail ?? "status=\(process.terminationStatus)"
        debugLog("remote.relay.exit \(detail)")
        scheduleReverseRelayRestartLocked(remotePath: remotePath, delay: 2.0)
    }

    private func scheduleReverseRelayRestartLocked(remotePath: String, delay: TimeInterval) {
        guard !isStopping else { return }
        reverseRelayRestartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reverseRelayRestartWorkItem = nil
            guard !self.isStopping else { return }
            guard self.reverseRelayProcess == nil else { return }
            guard self.daemonReady else { return }
            self.startReverseRelayLocked(remotePath: self.daemonRemotePath ?? remotePath)
        }
        reverseRelayRestartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func stopReverseRelayLocked() {
        reverseRelayStderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let reverseRelayProcess, reverseRelayProcess.isRunning {
            reverseRelayProcess.terminate()
        }
        reverseRelayProcess = nil
        stopReverseRelayViaControlMasterLocked()
        reverseRelayStderrPipe = nil
        reverseRelayStderrBuffer = ""
        cliRelayServer?.stop()
        cliRelayServer = nil
        removeRemoteRelayMetadataLocked()
    }

    private func handleProxyBrokerUpdateLocked(_ update: WorkspaceRemoteProxyBroker.Update) {
        guard !isStopping else { return }
        switch update {
        case .connecting:
            debugLog("remote.proxy.connecting \(debugConfigSummary())")
            if proxyEndpoint == nil {
                publishState(.connecting, detail: "Connecting to \(configuration.displayTarget)")
            }
        case .ready(let endpoint):
            debugLog("remote.proxy.ready host=\(endpoint.host) port=\(endpoint.port) \(debugConfigSummary())")
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            reconnectRetryCount = 0
            guard proxyEndpoint != endpoint else {
                recordHeartbeatActivityLocked()
                return
            }
            proxyEndpoint = endpoint
            publishProxyEndpoint(endpoint)
            updateRemotePortPollingStateLocked()
            publishPortsSnapshotLocked()
            publishState(
                .connected,
                detail: "Connected to \(configuration.displayTarget) via shared local proxy \(endpoint.host):\(endpoint.port)"
            )
            requestBootstrapRemoteTTYIfNeededLocked()
            recordHeartbeatActivityLocked()
        case .error(let detail):
            debugLog("remote.proxy.error detail=\(detail) \(debugConfigSummary())")
            remotePortScanGeneration &+= 1
            remotePortScanBurstActive = false
            remotePortScanActiveReason = nil
            remotePortScanPendingReason = nil
            remotePortScanCoalesceWorkItem?.cancel()
            remotePortScanCoalesceWorkItem = nil
            remoteScannedPortsByPanel.removeAll()
            stopRemotePortPollingLocked()
            polledRemotePorts = []
            keepPolledRemotePortsUntilTTYScan = false
            proxyEndpoint = nil
            publishProxyEndpoint(nil)
            publishPortsSnapshotLocked()
            publishState(.error, detail: "Remote proxy to \(configuration.displayTarget) unavailable: \(detail)")
            guard Self.shouldEscalateProxyErrorToBootstrap(detail) else { return }

            proxyLease?.release()
            proxyLease = nil
            daemonReady = false
            daemonBootstrapVersion = nil
            daemonRemotePath = nil

            let retrySchedule = scheduleReconnectLocked(baseDelay: 2.0)
            let retrySuffix = Self.retrySuffix(retry: retrySchedule.retry, delay: retrySchedule.delay)
            publishDaemonStatus(
                .error,
                detail: "Remote daemon transport needs re-bootstrap after proxy failure\(retrySuffix)"
            )
        }
    }

    @discardableResult
    private func scheduleReconnectLocked(baseDelay: TimeInterval) -> RetrySchedule {
        let retryNumber = reconnectRetryCount + 1
        let retryDelay = Self.retryDelay(baseDelay: baseDelay, retry: retryNumber)
        guard !isStopping else { return RetrySchedule(retry: retryNumber, delay: retryDelay) }
        reconnectWorkItem?.cancel()
        reconnectRetryCount = retryNumber
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isStopping else { return }
            guard self.proxyLease == nil else { return }
            self.beginConnectionAttemptLocked()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
        return RetrySchedule(retry: retryNumber, delay: retryDelay)
    }

    private func publishState(_ state: WorkspaceRemoteConnectionState, detail: String?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteConnectionStateUpdate(
                state,
                detail: detail,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishDaemonStatus(
        _ state: WorkspaceRemoteDaemonState,
        detail: String?,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil
    ) {
        let controllerID = self.controllerID
        let status = WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDaemonStatusUpdate(
                status,
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func publishProxyEndpoint(_ endpoint: BrowserProxyEndpoint?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteProxyEndpointUpdate(endpoint)
        }
    }

    private func publishPortsSnapshotLocked() {
        let controllerID = self.controllerID
        let detectedByPanel = remotePortScanTTYNames.keys.reduce(into: [UUID: [Int]]()) { result, panelId in
            result[panelId] = remoteScannedPortsByPanel[panelId] ?? []
        }
        let detected = Array(
            Set(polledRemotePorts)
                .union(detectedByPanel.values.flatMap { $0 })
        ).sorted()
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteDetectedSurfacePortsSnapshot(
                detectedByPanel: detectedByPanel,
                detected: detected,
                forwarded: [],
                conflicts: [],
                target: workspace.remoteDisplayTarget ?? "remote host"
            )
        }
    }

    private func recordHeartbeatActivityLocked() {
        heartbeatCount += 1
        publishHeartbeat(count: heartbeatCount, at: Date())
    }

    private func publishHeartbeat(count: Int, at date: Date?) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyRemoteHeartbeatUpdate(count: count, lastSeenAt: date)
        }
    }

    private func requestBootstrapRemoteTTYIfNeededLocked() {
        guard !bootstrapRemoteTTYResolved else { return }
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        if !remotePortScanTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = true
            bootstrapRemoteTTYRetryWorkItem?.cancel()
            bootstrapRemoteTTYRetryWorkItem = nil
            bootstrapRemoteTTYRetryCount = 0
            return
        }
        guard !bootstrapRemoteTTYFetchInFlight else { return }
        bootstrapRemoteTTYFetchInFlight = true
        defer { bootstrapRemoteTTYFetchInFlight = false }

        let command = "sh -c \(Self.shellSingleQuoted("tty_path=\"$HOME/.cmux/relay/\(relayPort).tty\"; if [ -r \"$tty_path\" ]; then cat \"$tty_path\"; fi"))"
        do {
            let result = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
                timeout: 2
            )
            guard result.status == 0 else {
                scheduleBootstrapRemoteTTYRetryLocked()
                return
            }
            guard let ttyName = Self.normalizedRemotePortScanTTYName(result.stdout) else {
                scheduleBootstrapRemoteTTYRetryLocked()
                return
            }
            bootstrapRemoteTTYResolved = true
            bootstrapRemoteTTYRetryWorkItem?.cancel()
            bootstrapRemoteTTYRetryWorkItem = nil
            bootstrapRemoteTTYRetryCount = 0
            debugLog("remote.tty.bootstrap.ready tty=\(ttyName) \(debugConfigSummary())")
            publishBootstrapRemoteTTY(ttyName)
        } catch {
            debugLog("remote.tty.bootstrap.failed error=\(error.localizedDescription) \(debugConfigSummary())")
            scheduleBootstrapRemoteTTYRetryLocked()
        }
    }

    private func scheduleBootstrapRemoteTTYRetryLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard !bootstrapRemoteTTYResolved else { return }
        guard remotePortScanTTYNames.isEmpty else { return }
        guard bootstrapRemoteTTYRetryCount < Self.bootstrapRemoteTTYRetryLimit else { return }
        guard bootstrapRemoteTTYRetryWorkItem == nil else { return }

        bootstrapRemoteTTYRetryCount += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bootstrapRemoteTTYRetryWorkItem = nil
            self.requestBootstrapRemoteTTYIfNeededLocked()
        }
        bootstrapRemoteTTYRetryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.bootstrapRemoteTTYRetryDelay, execute: workItem)
    }

    private func publishBootstrapRemoteTTY(_ ttyName: String) {
        let controllerID = self.controllerID
        DispatchQueue.main.async { [weak workspace] in
            guard let workspace else { return }
            guard workspace.activeRemoteSessionControllerID == controllerID else { return }
            workspace.applyBootstrapRemoteTTY(ttyName)
        }
    }

    private func reverseRelayArguments(relayPort: Int, localRelayPort: Int) -> [String] {
        // Fallback standalone transport when dynamic forwarding through an existing
        // control master is unavailable.
        var args: [String] = ["-N", "-T", "-S", "none"]
        args += sshCommonArguments(batchMode: true)
        args += [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "RequestTTY=no",
            "-R", "127.0.0.1:\(relayPort):127.0.0.1:\(localRelayPort)",
            configuration.destination,
        ]
        return args
    }

    private func startReverseRelayViaControlMasterLocked(forwardSpec: String) -> Bool {
        guard let arguments = WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterArguments(
            configuration: configuration,
            controlCommand: "forward",
            forwardSpec: forwardSpec
        ) else {
            return false
        }

        do {
            let result = try sshExec(arguments: arguments, timeout: 6)
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout)
                    ?? "ssh exited \(result.status)"
                debugLog("remote.relay.controlmaster.forwardFailed \(detail) \(debugConfigSummary())")
                return false
            }
            reverseRelayControlMasterForwardSpec = forwardSpec
            return true
        } catch {
            debugLog("remote.relay.controlmaster.forwardFailed \(error.localizedDescription) \(debugConfigSummary())")
            return false
        }
    }

    private func stopReverseRelayViaControlMasterLocked() {
        guard let forwardSpec = reverseRelayControlMasterForwardSpec else { return }
        reverseRelayControlMasterForwardSpec = nil
        guard let arguments = WorkspaceRemoteSSHBatchCommandBuilder.reverseRelayControlMasterArguments(
            configuration: configuration,
            controlCommand: "cancel",
            forwardSpec: forwardSpec
        ) else {
            return
        }
        _ = try? sshExec(arguments: arguments, timeout: 4)
    }

    private static let remotePlatformProbeOSMarker = "__CMUX_REMOTE_OS__="
    private static let remotePlatformProbeArchMarker = "__CMUX_REMOTE_ARCH__="
    private static let remotePlatformProbeExistsMarker = "__CMUX_REMOTE_EXISTS__="
    private static let bootstrapRemoteTTYRetryDelay: TimeInterval = 0.5
    private static let bootstrapRemoteTTYRetryLimit = 8

    private func sshCommonArguments(batchMode: Bool) -> [String] {
        let effectiveSSHOptions: [String] = {
            if batchMode {
                return backgroundSSHOptions(configuration.sshOptions)
            }
            return normalizedSSHOptions(configuration.sshOptions)
        }()
        var args: [String] = [
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
        ]
        if !hasSSHOptionKey(effectiveSSHOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        if batchMode {
            args += ["-o", "BatchMode=yes"]
            args += ["-o", "ControlMaster=no"]
        }
        if let port = configuration.port {
            args += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        for option in effectiveSSHOptions {
            args += ["-o", option]
        }
        return args
    }

    private func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        for option in options {
            let token = sshOptionKey(option)
            if token == loweredKey {
                return true
            }
        }
        return false
    }

    private func normalizedSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private func backgroundSSHOptions(_ options: [String]) -> [String] {
        let batchSSHControlOptionKeys: Set<String> = [
            "controlmaster",
            "controlpersist",
        ]
        return normalizedSSHOptions(options).filter { option in
            guard let key = sshOptionKey(option) else { return false }
            return !batchSSHControlOptionKeys.contains(key)
        }
    }

    private func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private func sshExec(arguments: [String], stdin: Data? = nil, timeout: TimeInterval = 15) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            stdin: stdin,
            timeout: timeout
        )
    }

    private func scpExec(
        arguments: [String],
        timeout: TimeInterval = 30,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
        try runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            stdin: nil,
            timeout: timeout,
            operation: operation
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        stdin: Data?,
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
        debugLog(
            "remote.proc.start exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if stdin != nil {
            process.standardInput = Pipe()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let captureQueue = DispatchQueue(label: "cmux.remote.process.capture")
        let exitSemaphore = DispatchSemaphore(value: 0)
        var stdoutData = Data()
        var stderrData = Data()
        let captureGroup = DispatchGroup()
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutHandle.readDataToEndOfFile()
            captureQueue.sync {
                stdoutData = data
            }
            captureGroup.leave()
        }
        captureGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrHandle.readDataToEndOfFile()
            captureQueue.sync {
                stderrData = data
            }
            captureGroup.leave()
        }

        do {
            try operation?.throwIfCancelled()
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            debugLog(
                "remote.proc.launchFailed exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "error=\(error.localizedDescription)"
            )
            throw NSError(domain: "cmux.remote.process", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)",
            ])
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        operation?.installCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        if let stdin, let pipe = process.standardInput as? Pipe {
            pipe.fileHandleForWriting.write(stdin)
            try? pipe.fileHandleForWriting.close()
        }

        func terminateProcessAndWait() {
            process.terminate()
            let terminatedGracefully = exitSemaphore.wait(timeout: .now() + 2.0) == .success
            if !terminatedGracefully, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let didExitBeforeTimeout = exitSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
        if !didExitBeforeTimeout, process.isRunning {
            if operation?.isCancelled == true {
                terminateProcessAndWait()
                throw TerminalImageTransferExecutionError.cancelled
            }
            terminateProcessAndWait()
            debugLog(
                "remote.proc.timeout exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
                "timeout=\(Int(timeout)) args=\(debugShellCommand(executable: executable, arguments: arguments))"
            )
            throw NSError(domain: "cmux.remote.process", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(Int(timeout))s",
            ])
        }

        _ = captureGroup.wait(timeout: .now() + 2.0)
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if operation?.isCancelled == true {
            throw TerminalImageTransferExecutionError.cancelled
        }
        debugLog(
            "remote.proc.end exec=\(URL(fileURLWithPath: executable).lastPathComponent) " +
            "status=\(process.terminationStatus) stdout=\(Self.debugLogSnippet(stdout)) " +
            "stderr=\(Self.debugLogSnippet(stderr))"
        )
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func bootstrapDaemonLocked() throws -> DaemonHello {
        debugLog("remote.bootstrap.begin \(debugConfigSummary())")
        let version = Self.remoteDaemonVersion()
        let bootstrapState = try probeRemoteBootstrapStateLocked(version: version)
        let platform = bootstrapState.platform
        let remotePath = Self.remoteDaemonPath(version: version, goOS: platform.goOS, goArch: platform.goArch)
        let explicitOverrideBinary = Self.explicitRemoteDaemonBinaryURL()
        let forceExplicitOverrideInstall = explicitOverrideBinary != nil
        debugLog(
            "remote.bootstrap.platform os=\(platform.goOS) arch=\(platform.goArch) " +
            "version=\(version) remotePath=\(remotePath) " +
            "allowLocalBuildFallback=\(Self.allowLocalDaemonBuildFallback() ? 1 : 0) " +
            "explicitOverride=\(forceExplicitOverrideInstall ? 1 : 0)"
        )

        let hadExistingBinary = bootstrapState.binaryExists
        debugLog("remote.bootstrap.binaryExists remotePath=\(remotePath) exists=\(hadExistingBinary ? 1 : 0)")
        if forceExplicitOverrideInstall || !hadExistingBinary {
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
        }

        var hello: DaemonHello
        do {
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        } catch {
            guard hadExistingBinary else {
                throw error
            }
            debugLog(
                "remote.bootstrap.helloRetry remotePath=\(remotePath) " +
                "detail=\(error.localizedDescription)"
            )
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }
        if hadExistingBinary, !hello.capabilities.contains(WorkspaceRemoteDaemonRPCClient.requiredProxyStreamCapability) {
            debugLog("remote.bootstrap.capabilityMissing remotePath=\(remotePath) capabilities=\(hello.capabilities.joined(separator: ","))")
            let localBinary = try buildLocalDaemonBinary(goOS: platform.goOS, goArch: platform.goArch, version: version)
            try uploadRemoteDaemonBinaryLocked(localBinary: localBinary, remotePath: remotePath)
            hello = try helloRemoteDaemonLocked(remotePath: remotePath)
        }

        debugLog(
            "remote.bootstrap.ready name=\(hello.name) version=\(hello.version) " +
            "capabilities=\(hello.capabilities.joined(separator: ",")) remotePath=\(hello.remotePath)"
        )
        if let connectionAttemptStartedAt {
            debugLog(
                "remote.timing.bootstrap.ready elapsedMs=\(Int(Date().timeIntervalSince(connectionAttemptStartedAt) * 1000)) " +
                "\(debugConfigSummary())"
            )
        }
        return hello
    }

    private func ensureCLIRelayServerLocked(localSocketPath: String, relayID: String, relayToken: String) throws -> WorkspaceRemoteCLIRelayServer {
        if let cliRelayServer {
            return cliRelayServer
        }
        let relayServer = try WorkspaceRemoteCLIRelayServer(
            localSocketPath: localSocketPath,
            relayID: relayID,
            relayTokenHex: relayToken
        )
        cliRelayServer = relayServer
        return relayServer
    }

    private func installRemoteRelayMetadataLocked(
        remotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) throws {
        let script = Self.remoteRelayMetadataInstallScript(
            daemonRemotePath: remotePath,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken
        )
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.relay", code: 70, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote relay metadata: \(detail)",
            ])
        }
    }

    private func removeRemoteRelayMetadataLocked() {
        guard let relayPort = configuration.relayPort, relayPort > 0 else { return }
        let script = Self.remoteRelayMetadataCleanupScript(relayPort: relayPort)
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        do {
            _ = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 8)
        } catch {
            debugLog("remote.relay.cleanup.error \(error.localizedDescription)")
        }
    }

    static func remoteRelayMetadataCleanupScript(relayPort: Int) -> String {
        """
        relay_socket='127.0.0.1:\(relayPort)'
        socket_addr_file="$HOME/.cmux/socket_addr"
        if [ -r "$socket_addr_file" ] && [ "$(tr -d '\\r\\n' < "$socket_addr_file")" = "$relay_socket" ]; then
          rm -f "$socket_addr_file"
        fi
        rm -f "$HOME/.cmux/relay/\(relayPort).auth" "$HOME/.cmux/relay/\(relayPort).daemon_path" "$HOME/.cmux/relay/\(relayPort).tty"
        """
    }

    private func probeRemoteBootstrapStateLocked(version: String) throws -> RemoteBootstrapState {
        let script = """
        cmux_uname_os="$(uname -s)"
        cmux_uname_arch="$(uname -m)"
        printf '%s%s\\n' '\(Self.remotePlatformProbeOSMarker)' "$cmux_uname_os"
        printf '%s%s\\n' '\(Self.remotePlatformProbeArchMarker)' "$cmux_uname_arch"
        case "$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" in
          linux|darwin|freebsd) cmux_go_os="$(printf '%s' "$cmux_uname_os" | tr '[:upper:]' '[:lower:]')" ;;
          *) exit 70 ;;
        esac
        case "$(printf '%s' "$cmux_uname_arch" | tr '[:upper:]' '[:lower:]')" in
          x86_64|amd64) cmux_go_arch=amd64 ;;
          aarch64|arm64) cmux_go_arch=arm64 ;;
          armv7l) cmux_go_arch=arm ;;
          *) exit 71 ;;
        esac
        cmux_remote_path="$HOME/.cmux/bin/cmuxd-remote/\(version)/${cmux_go_os}-${cmux_go_arch}/cmuxd-remote"
        if [ -x "$cmux_remote_path" ]; then
          printf '%syes\\n' '\(Self.remotePlatformProbeExistsMarker)'
        else
          printf '%sno\\n' '\(Self.remotePlatformProbeExistsMarker)'
        fi
        """
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 20)

        let lines = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unameOS = lines.first { $0.hasPrefix(Self.remotePlatformProbeOSMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeOSMarker.count)) }
        let unameArch = lines.first { $0.hasPrefix(Self.remotePlatformProbeArchMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeArchMarker.count)) }
        guard let unameOS, let unameArch else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote platform: \(detail)",
            ])
        }

        guard let goOS = Self.mapUnameOS(unameOS),
              let goArch = Self.mapUnameArch(unameArch) else {
            throw NSError(domain: "cmux.remote.daemon", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "unsupported remote platform \(unameOS)/\(unameArch)",
            ])
        }

        let binaryExists = lines.first { $0.hasPrefix(Self.remotePlatformProbeExistsMarker) }
            .map { String($0.dropFirst(Self.remotePlatformProbeExistsMarker.count)) == "yes" }
        if result.status != 0, binaryExists == nil {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "failed to query remote daemon state: \(detail)",
            ])
        }

        return RemoteBootstrapState(
            platform: RemotePlatform(goOS: goOS, goArch: goArch),
            binaryExists: binaryExists ?? false
        )
    }

    static let remoteDaemonManifestInfoKey = "CMUXRemoteDaemonManifestJSON"

    static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        guard let rawManifest = infoDictionary?[remoteDaemonManifestInfoKey] as? String else { return nil }
        let trimmed = rawManifest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    private static func remoteDaemonManifest() -> WorkspaceRemoteDaemonManifest? {
        remoteDaemonManifest(from: Bundle.main.infoDictionary)
    }

    private static func remoteDaemonCacheRoot(fileManager: FileManager = .default) throws -> URL {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheRoot = appSupportRoot
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("remote-daemons", isDirectory: true)
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return cacheRoot
    }

    static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try remoteDaemonCacheRoot(fileManager: fileManager)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    private static func sha256Hex(forFile url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func allowLocalDaemonBuildFallback(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1"
    }

    private static func explicitRemoteDaemonBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard allowLocalDaemonBuildFallback(environment: environment) else { return nil }
        guard let path = environment["CMUX_REMOTE_DAEMON_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    private static func versionedRemoteDaemonBuildURL(goOS: String, goArch: String, version: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-remote-daemon-build", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("\(goOS)-\(goArch)", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
    }

    /// Fetch the live manifest JSON from the release, returning nil on any failure.
    private static func fetchRemoteManifestLocked(releaseURL: String, version: String) -> WorkspaceRemoteDaemonManifest? {
        guard let manifestURL = URL(string: "\(releaseURL)/cmuxd-remote-manifest.json") else { return nil }
        let request = NSMutableURLRequest(url: manifestURL)
        request.timeoutInterval = 15
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        session.dataTask(with: request as URLRequest) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            resultData = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20.0)
        session.finishTasksAndInvalidate()
        guard let data = resultData else { return nil }
        return try? JSONDecoder().decode(WorkspaceRemoteDaemonManifest.self, from: data)
    }

    private func downloadRemoteDaemonBinaryLocked(entry: WorkspaceRemoteDaemonManifest.Entry, version: String, releaseURL: String? = nil) throws -> URL {
        guard let url = URL(string: entry.downloadURL) else {
            throw NSError(domain: "cmux.remote.daemon", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon manifest has an invalid download URL",
            ])
        }

        let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: version, goOS: entry.goOS, goArch: entry.goArch)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let request = NSMutableURLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("cmux/\(version)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)

        let semaphore = DispatchSemaphore(value: 0)
        var downloadedURL: URL?
        var downloadError: Error?
        session.downloadTask(with: request as URLRequest) { localURL, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = error
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                downloadError = NSError(domain: "cmux.remote.daemon", code: 26, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon download failed with HTTP \(httpResponse.statusCode)",
                ])
                return
            }
            downloadedURL = localURL
        }.resume()
        _ = semaphore.wait(timeout: .now() + 75.0)
        session.finishTasksAndInvalidate()

        if let downloadError {
            throw downloadError
        }
        guard let downloadedURL else {
            throw NSError(domain: "cmux.remote.daemon", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon download did not produce a file",
            ])
        }

        let downloadedSHA = try Self.sha256Hex(forFile: downloadedURL)
        if downloadedSHA != entry.sha256.lowercased() {
            // The embedded manifest's checksum doesn't match the downloaded binary.
            // This can happen when a newer nightly overwrites the shared release
            // asset after this build's manifest was embedded. As a fallback, fetch
            // the live manifest from the release and verify against that.
            if let releaseURL,
               let liveManifest = Self.fetchRemoteManifestLocked(releaseURL: releaseURL, version: version),
               let liveEntry = liveManifest.entry(goOS: entry.goOS, goArch: entry.goArch),
               downloadedSHA == liveEntry.sha256.lowercased() {
                debugLog("remote.download.checksum-fallback: embedded manifest checksum stale, live manifest matched for \(entry.assetName)")
            } else {
                throw NSError(domain: "cmux.remote.daemon", code: 28, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon checksum mismatch for \(entry.assetName)",
                ])
            }
        }

        let tempURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: tempURL)
        try fileManager.moveItem(at: downloadedURL, to: tempURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        try? fileManager.removeItem(at: cacheURL)
        try fileManager.moveItem(at: tempURL, to: cacheURL)
        return cacheURL
    }

    private func buildLocalDaemonBinary(goOS: String, goArch: String, version: String) throws -> URL {
        if let explicitBinary = Self.explicitRemoteDaemonBinaryURL(),
           FileManager.default.isExecutableFile(atPath: explicitBinary.path) {
            debugLog("remote.build.explicit path=\(explicitBinary.path)")
            return explicitBinary
        }

        if let manifest = Self.remoteDaemonManifest(),
           manifest.appVersion == version,
           let entry = manifest.entry(goOS: goOS, goArch: goArch) {
            let cacheURL = try Self.remoteDaemonCachedBinaryURL(version: manifest.appVersion, goOS: goOS, goArch: goArch)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let cachedSHA = try Self.sha256Hex(forFile: cacheURL)
                if cachedSHA == entry.sha256.lowercased(),
                   FileManager.default.isExecutableFile(atPath: cacheURL.path) {
                    debugLog("remote.build.cached path=\(cacheURL.path)")
                    return cacheURL
                }
                try? FileManager.default.removeItem(at: cacheURL)
            }
            let downloadedURL = try downloadRemoteDaemonBinaryLocked(entry: entry, version: manifest.appVersion, releaseURL: manifest.releaseURL)
            debugLog("remote.build.downloaded path=\(downloadedURL.path)")
            return downloadedURL
        }

        guard Self.allowLocalDaemonBuildFallback() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "this build does not include a verified cmuxd-remote manifest for \(goOS)-\(goArch). Use a release/nightly build, or set CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1 for a dev-only fallback.",
            ])
        }

        guard let repoRoot = Self.findRepoRoot() else {
            throw NSError(domain: "cmux.remote.daemon", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "cannot locate cmux repo root for dev-only cmuxd-remote build fallback",
            ])
        }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        let goModPath = daemonRoot.appendingPathComponent("go.mod").path
        guard FileManager.default.fileExists(atPath: goModPath) else {
            throw NSError(domain: "cmux.remote.daemon", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "missing daemon module at \(goModPath)",
            ])
        }
        guard let goBinary = Self.which("go") else {
            throw NSError(domain: "cmux.remote.daemon", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "go is required for the dev-only cmuxd-remote build fallback",
            ])
        }

        let output = Self.versionedRemoteDaemonBuildURL(goOS: goOS, goArch: goArch, version: version)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        var env = ProcessInfo.processInfo.environment
        env["GOOS"] = goOS
        env["GOARCH"] = goArch
        env["CGO_ENABLED"] = "0"
        let ldflags = "-s -w -X main.version=\(version)"
        let result = try runProcess(
            executable: goBinary,
            arguments: ["build", "-trimpath", "-buildvcs=false", "-ldflags", ldflags, "-o", output.path, "./cmd/cmuxd-remote"],
            environment: env,
            currentDirectory: daemonRoot,
            stdin: nil,
            timeout: 90
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "go build failed with status \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "failed to build cmuxd-remote: \(detail)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: output.path) else {
            throw NSError(domain: "cmux.remote.daemon", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "cmuxd-remote build output is not executable",
            ])
        }
        debugLog("remote.build.output path=\(output.path)")
        return output
    }

    private func uploadRemoteDaemonBinaryLocked(localBinary: URL, remotePath: String) throws {
        let remoteDirectory = (remotePath as NSString).deletingLastPathComponent
        let remoteTempPath = "\(remotePath).tmp-\(UUID().uuidString.prefix(8))"
        debugLog(
            "remote.upload.begin local=\(localBinary.path) remoteTemp=\(remoteTempPath) remote=\(remotePath)"
        )

        let mkdirScript = "mkdir -p \(Self.shellSingleQuoted(remoteDirectory))"
        let mkdirCommand = "sh -c \(Self.shellSingleQuoted(mkdirScript))"
        let mkdirResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, mkdirCommand], timeout: 12)
        guard mkdirResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: mkdirResult.stderr, stdout: mkdirResult.stdout) ?? "ssh exited \(mkdirResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "failed to create remote daemon directory: \(detail)",
            ])
        }

        let scpSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        var scpArgs: [String] = ["-q"]
        if !hasSSHOptionKey(scpSSHOptions, key: "StrictHostKeyChecking") {
            scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        scpArgs += ["-o", "ControlMaster=no"]
        if let port = configuration.port {
            scpArgs += ["-P", String(port)]
        }
        if let identityFile = configuration.identityFile,
           !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scpArgs += ["-i", identityFile]
        }
        for option in scpSSHOptions {
            scpArgs += ["-o", option]
        }
        scpArgs += [localBinary.path, "\(configuration.destination):\(remoteTempPath)"]
        let scpResult = try scpExec(arguments: scpArgs, timeout: 45)
        guard scpResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ?? "scp exited \(scpResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "failed to upload cmuxd-remote: \(detail)",
            ])
        }

        let finalizeScript = """
        chmod 755 \(Self.shellSingleQuoted(remoteTempPath)) && \
        mv \(Self.shellSingleQuoted(remoteTempPath)) \(Self.shellSingleQuoted(remotePath))
        """
        let finalizeCommand = "sh -c \(Self.shellSingleQuoted(finalizeScript))"
        let finalizeResult = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, finalizeCommand], timeout: 12)
        guard finalizeResult.status == 0 else {
            let detail = Self.bestErrorLine(stderr: finalizeResult.stderr, stdout: finalizeResult.stdout) ?? "ssh exited \(finalizeResult.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "failed to install remote daemon binary: \(detail)",
            ])
        }
    }

    private func uploadDroppedFilesLocked(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation
    ) throws -> [String] {
        guard !fileURLs.isEmpty else { return [] }

        let scpSSHOptions = backgroundSSHOptions(configuration.sshOptions)
        var uploadedRemotePaths: [String] = []
        do {
            for localURL in fileURLs {
                try operation.throwIfCancelled()
                let normalizedLocalURL = localURL.standardizedFileURL
                guard normalizedLocalURL.isFileURL else {
                    throw RemoteDropUploadError.invalidFileURL
                }

                let remotePath = Self.remoteDropPath(for: normalizedLocalURL)
                uploadedRemotePaths.append(remotePath)
                var scpArgs: [String] = ["-q", "-o", "ControlMaster=no"]
                if !hasSSHOptionKey(scpSSHOptions, key: "StrictHostKeyChecking") {
                    scpArgs += ["-o", "StrictHostKeyChecking=accept-new"]
                }
                if let port = configuration.port {
                    scpArgs += ["-P", String(port)]
                }
                if let identityFile = configuration.identityFile,
                   !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scpArgs += ["-i", identityFile]
                }
                for option in scpSSHOptions {
                    scpArgs += ["-o", option]
                }
                scpArgs += [normalizedLocalURL.path, "\(configuration.destination):\(remotePath)"]

                let scpResult = try scpExec(arguments: scpArgs, timeout: 45, operation: operation)
                guard scpResult.status == 0 else {
                    let detail = Self.bestErrorLine(stderr: scpResult.stderr, stdout: scpResult.stdout) ??
                        "scp exited \(scpResult.status)"
                    throw RemoteDropUploadError.uploadFailed(detail)
                }
            }
            return uploadedRemotePaths
        } catch {
            cleanupUploadedRemotePaths(uploadedRemotePaths)
            throw error
        }
    }

    static func remoteDropPath(for fileURL: URL, uuid: UUID = UUID()) -> String {
        let extensionSuffix = fileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedSuffix = extensionSuffix.isEmpty ? "" : ".\(extensionSuffix.lowercased())"
        return "/tmp/cmux-drop-\(uuid.uuidString.lowercased())\(lowercasedSuffix)"
    }

    private func cleanupUploadedRemotePaths(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let cleanupScript = "rm -f -- " + remotePaths.map(Self.shellSingleQuoted).joined(separator: " ")
        let cleanupCommand = "sh -c \(Self.shellSingleQuoted(cleanupScript))"
        _ = try? sshExec(
            arguments: sshCommonArguments(batchMode: true) + [configuration.destination, cleanupCommand],
            timeout: 8
        )
    }

    private func helloRemoteDaemonLocked(remotePath: String) throws -> DaemonHello {
        let request = #"{"id":1,"method":"hello","params":{}}"#
        let script = "printf '%s\\n' \(Self.shellSingleQuoted(request)) | \(Self.shellSingleQuoted(remotePath)) serve --stdio"
        let command = "sh -c \(Self.shellSingleQuoted(script))"
        let result = try sshExec(arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command], timeout: 12)
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.daemon", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "failed to start remote daemon: \(detail)",
            ])
        }

        let responseLine = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        guard !responseLine.isEmpty,
              let data = responseLine.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw NSError(domain: "cmux.remote.daemon", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello returned invalid JSON",
            ])
        }

        if let ok = payload["ok"] as? Bool, !ok {
            let errorMessage: String = {
                if let errorObject = payload["error"] as? [String: Any],
                   let message = errorObject["message"] as? String,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                return "hello call failed"
            }()
            throw NSError(domain: "cmux.remote.daemon", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "remote daemon hello failed: \(errorMessage)",
            ])
        }

        let resultObject = payload["result"] as? [String: Any] ?? [:]
        let name = (resultObject["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (resultObject["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities = (resultObject["capabilities"] as? [String]) ?? []
        return DaemonHello(
            name: (name?.isEmpty == false ? name! : "cmuxd-remote"),
            version: (version?.isEmpty == false ? version! : "dev"),
            capabilities: capabilities,
            remotePath: remotePath
        )
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        dlog(message())
#endif
    }

    private func debugConfigSummary() -> String {
        let controlPath = Self.debugSSHOptionValue(named: "ControlPath", in: configuration.sshOptions) ?? "nil"
        return
            "target=\(configuration.displayTarget) port=\(configuration.port.map(String.init) ?? "nil") " +
            "relayPort=\(configuration.relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(configuration.localSocketPath ?? "nil") " +
            "controlPath=\(controlPath)"
    }

    private func debugShellCommand(executable: String, arguments: [String]) -> String {
        ([URL(fileURLWithPath: executable).lastPathComponent] + arguments)
            .map(Self.shellSingleQuoted)
            .joined(separator: " ")
    }

    private static func debugSSHOptionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == loweredKey {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func debugLogSnippet(_ text: String, limit: Int = 160) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "\"\"" }
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func remoteCLIWrapperScript() -> String {
        """
        #!/bin/sh
        set -eu

        daemon="$HOME/.cmux/bin/cmuxd-remote-current"
        socket_path="${CMUX_SOCKET_PATH:-}"
        if [ -z "$socket_path" ] && [ -r "$HOME/.cmux/socket_addr" ]; then
          socket_path="$(tr -d '\\r\\n' < "$HOME/.cmux/socket_addr")"
        fi

        if [ -n "$socket_path" ] && [ "${socket_path#/}" = "$socket_path" ] && [ "${socket_path#*:}" != "$socket_path" ]; then
          relay_port="${socket_path##*:}"
          relay_map="$HOME/.cmux/relay/${relay_port}.daemon_path"
          if [ -r "$relay_map" ]; then
            mapped_daemon="$(tr -d '\\r\\n' < "$relay_map")"
            if [ -n "$mapped_daemon" ] && [ -x "$mapped_daemon" ]; then
              daemon="$mapped_daemon"
            fi
          fi
        fi

        exec "$daemon" "$@"
        """
    }

    static func remoteCLIWrapperInstallScript(daemonRemotePath: String) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        mkdir -p "$HOME/.cmux/bin" "$HOME/.cmux/relay"
        ln -sf "$HOME/\(trimmedRemotePath)" "$HOME/.cmux/bin/cmuxd-remote-current"
        wrapper_tmp="$HOME/.cmux/bin/.cmux-wrapper.tmp.$$"
        cat > "$wrapper_tmp" <<'CMUXWRAPPER'
        \(remoteCLIWrapperScript())
        CMUXWRAPPER
        chmod 755 "$wrapper_tmp"
        mv -f "$wrapper_tmp" "$HOME/.cmux/bin/cmux"
        """
    }

    static func remoteRelayMetadataInstallScript(
        daemonRemotePath: String,
        relayPort: Int,
        relayID: String,
        relayToken: String
    ) -> String {
        let trimmedRemotePath = daemonRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let authPayload = """
        {"relay_id":"\(relayID)","relay_token":"\(relayToken)"}
        """
        return """
        umask 077
        mkdir -p "$HOME/.cmux" "$HOME/.cmux/relay"
        chmod 700 "$HOME/.cmux/relay"
        \(remoteCLIWrapperInstallScript(daemonRemotePath: trimmedRemotePath))
        printf '%s' "$HOME/\(trimmedRemotePath)" > "$HOME/.cmux/relay/\(relayPort).daemon_path"
        cat > "$HOME/.cmux/relay/\(relayPort).auth" <<'CMUXRELAYAUTH'
        \(authPayload)
        CMUXRELAYAUTH
        chmod 600 "$HOME/.cmux/relay/\(relayPort).auth"
        printf '%s' '127.0.0.1:\(relayPort)' > "$HOME/.cmux/socket_addr"
        """
    }

    private static func mapUnameOS(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "linux":
            return "linux"
        case "darwin":
            return "darwin"
        case "freebsd":
            return "freebsd"
        default:
            return nil
        }
    }

    private static func mapUnameArch(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "x86_64", "amd64":
            return "amd64"
        case "aarch64", "arm64":
            return "arm64"
        case "armv7l":
            return "arm"
        default:
            return nil
        }
    }

    private static func remoteDaemonVersion() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseVersion = (bundleVersion?.isEmpty == false) ? bundleVersion! : "dev"
        guard allowLocalDaemonBuildFallback(),
              let sourceFingerprint = remoteDaemonSourceFingerprint(),
              !sourceFingerprint.isEmpty else {
            return baseVersion
        }
        return "\(baseVersion)-dev-\(sourceFingerprint)"
    }

    private static let cachedRemoteDaemonSourceFingerprint: String? = computeRemoteDaemonSourceFingerprint()

    private static func remoteDaemonSourceFingerprint() -> String? {
        cachedRemoteDaemonSourceFingerprint
    }

    private static func computeRemoteDaemonSourceFingerprint(fileManager: FileManager = .default) -> String? {
        guard let repoRoot = findRepoRoot() else { return nil }
        let daemonRoot = repoRoot.appendingPathComponent("daemon/remote", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: daemonRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var relativePaths: [String] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: daemonRoot.path + "/", with: "")
            if relativePath == "go.mod" || relativePath == "go.sum" || relativePath.hasSuffix(".go") {
                relativePaths.append(relativePath)
            }
        }

        guard !relativePaths.isEmpty else { return nil }

        let digest = SHA256.hash(data: relativePaths.sorted().reduce(into: Data()) { partialResult, relativePath in
            let fileURL = daemonRoot.appendingPathComponent(relativePath, isDirectory: false)
            guard let fileData = try? Data(contentsOf: fileURL) else { return }
            partialResult.append(Data(relativePath.utf8))
            partialResult.append(0)
            partialResult.append(fileData)
            partialResult.append(0)
        })
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    private static func remoteDaemonPath(version: String, goOS: String, goArch: String) -> String {
        ".cmux/bin/cmuxd-remote/\(version)/\(goOS)-\(goArch)/cmuxd-remote"
    }

    static func orphanedCMUXRemoteSSHPIDs(
        psOutput: String,
        destination: String,
        relayPort: Int? = nil
    ) -> [Int] {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return [] }

        return psOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> Int? in
                guard let parsed = parsePSLine(line) else { return nil }
                guard parsed.ppid == 1 else { return nil }
                guard isOrphanedCMUXRemoteSSHCommand(
                    parsed.command,
                    destination: trimmedDestination,
                    relayPort: relayPort
                ) else {
                    return nil
                }
                return parsed.pid
            }
            .sorted()
    }

    private static func killOrphanedRemoteSSHProcesses(destination: String, relayPort: Int? = nil) {
        guard let output = captureCommandStandardOutput(
            executablePath: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,command="]
        ) else {
            return
        }

        for pid in orphanedCMUXRemoteSSHPIDs(
            psOutput: output,
            destination: destination,
            relayPort: relayPort
        ) {
            _ = Darwin.kill(pid_t(pid), SIGTERM)
        }
    }

    private static func captureCommandStandardOutput(
        executablePath: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: outputData, encoding: .utf8),
                  !output.isEmpty else {
                return nil
            }
            return output
        } catch {
            // Best effort cleanup only.
            return nil
        }
    }

    private static func parsePSLine(_ line: Substring) -> (pid: Int, ppid: Int, command: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let scanner = Scanner(string: trimmed)
        var pidValue: Int = 0
        var ppidValue: Int = 0
        guard scanner.scanInt(&pidValue), scanner.scanInt(&ppidValue) else {
            return nil
        }

        let commandStart = scanner.currentIndex
        let command = String(trimmed[commandStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return (pidValue, ppidValue, command)
    }

    private static func isOrphanedCMUXRemoteSSHCommand(
        _ command: String,
        destination: String,
        relayPort: Int?
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.hasPrefix("/usr/bin/ssh ") || trimmed.hasPrefix("ssh ") else { return false }
        guard commandContainsDestination(trimmed, destination: destination) else { return false }

        if let relayPort {
            return trimmed.contains(" -N ")
                && trimmed.contains(" -R 127.0.0.1:\(relayPort):127.0.0.1:")
        }

        if trimmed.contains(" -N ") && trimmed.contains(" -R 127.0.0.1:") {
            return true
        }
        if trimmed.contains("cmuxd-remote") && trimmed.contains(" serve --stdio") {
            return true
        }
        return false
    }

    private static func commandContainsDestination(_ command: String, destination: String) -> Bool {
        guard !destination.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: destination)
        guard let regex = try? NSRegularExpression(
            pattern: "(^|[\\s'\\\"])\(escaped)($|[\\s'\\\"])",
            options: []
        ) else {
            return command.contains(destination)
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.firstMatch(in: command, options: [], range: range) != nil
    }

    static func executableSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pathHelperOutput: String? = nil
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func appendSearchPath(_ rawPath: String?) {
            guard let rawPath else { return }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        if let path = environment["PATH"] {
            for component in path.split(separator: ":") {
                appendSearchPath(String(component))
            }
        }

        if let home = environment["HOME"], !home.isEmpty {
            appendSearchPath((home as NSString).appendingPathComponent(".local/bin"))
            appendSearchPath((home as NSString).appendingPathComponent("go/bin"))
            appendSearchPath((home as NSString).appendingPathComponent("bin"))
        }

        let helperOutput = pathHelperOutput ?? pathHelperShellOutput()
        for component in parsePathHelperPaths(helperOutput) {
            appendSearchPath(component)
        }

        for component in [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ] {
            appendSearchPath(component)
        }

        return ordered
    }

    static func parsePathHelperPaths(_ output: String) -> [String] {
        for fragment in output.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("PATH=\"") else { continue }
            let suffix = trimmed.dropFirst("PATH=\"".count)
            guard let closingQuote = suffix.firstIndex(of: "\"") else { return [] }
            return suffix[..<closingQuote]
                .split(separator: ":")
                .map(String.init)
        }
        return []
    }

    private static func pathHelperShellOutput() -> String {
        let executable = "/usr/libexec/path_helper"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return "" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ""
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func which(_ executable: String) -> String? {
        for component in executableSearchPaths() {
            let candidate = (component as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func findRepoRoot() -> URL? {
        var candidates: [URL] = []
        let compileTimeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        candidates.append(compileTimeRoot)
        let environment = ProcessInfo.processInfo.environment
        if let envRoot = environment["CMUX_REMOTE_DAEMON_SOURCE_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        if let envRoot = environment["CMUXTERM_REPO_ROOT"],
           !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(URL(fileURLWithPath: envRoot, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable)
            candidates.append(executable.deletingLastPathComponent())
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fm = FileManager.default
        for base in candidates {
            var cursor = base.standardizedFileURL
            for _ in 0..<10 {
                let marker = cursor.appendingPathComponent("daemon/remote/go.mod").path
                if fm.fileExists(atPath: marker) {
                    return cursor
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path {
                    break
                }
                cursor = parent
            }
        }
        return nil
    }

    private static func bestErrorLine(stderr: String, stdout: String = "") -> String? {
        if let stderrLine = meaningfulErrorLine(in: stderr) {
            return stderrLine
        }
        if let stdoutLine = meaningfulErrorLine(in: stdout) {
            return stdoutLine
        }
        return nil
    }

    static func reverseRelayStartupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval = reverseRelayStartupGracePeriod
    ) -> String? {
        if process.isRunning {
            let originalTerminationHandler = process.terminationHandler
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { terminated in
                originalTerminationHandler?(terminated)
                exitSemaphore.signal()
            }
            if !process.isRunning {
                exitSemaphore.signal()
            }
            guard exitSemaphore.wait(timeout: .now() + max(0, gracePeriod)) == .success else {
                return nil
            }
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return bestErrorLine(stderr: stderr) ?? "status=\(process.terminationStatus)"
    }

    private static func meaningfulErrorLine(in text: String) -> String? {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    private static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }

    private static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    private static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }

    private static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }

    func updateRemotePortScanTTYs(_ ttyNames: [UUID: String]) {
        queue.async { [weak self] in
            self?.updateRemotePortScanTTYsLocked(ttyNames)
        }
    }

    func kickRemotePortScan(panelId: UUID, reason: PortScanKickReason = .command) {
        queue.async { [weak self] in
            self?.kickRemotePortScanLocked(panelId: panelId, reason: reason)
        }
    }

    private func updateRemotePortScanTTYsLocked(_ ttyNames: [UUID: String]) {
        let previousTTYNames = remotePortScanTTYNames
        let nextTTYNames = ttyNames.reduce(into: [UUID: String]()) { result, entry in
            guard let ttyName = Self.normalizedRemotePortScanTTYName(entry.value) else { return }
            result[entry.key] = ttyName
        }
        guard previousTTYNames != nextTTYNames else { return }
        if !nextTTYNames.isEmpty {
            bootstrapRemoteTTYResolved = true
            bootstrapRemoteTTYRetryWorkItem?.cancel()
            bootstrapRemoteTTYRetryWorkItem = nil
            bootstrapRemoteTTYRetryCount = 0
        }
        keepPolledRemotePortsUntilTTYScan =
            !previousTTYNames.isEmpty
            ? keepPolledRemotePortsUntilTTYScan
            : shouldUseFallbackRemotePortPollingLocked() && !polledRemotePorts.isEmpty && !nextTTYNames.isEmpty
        remoteScannedPortsByPanel = remoteScannedPortsByPanel.filter { panelId, _ in
            guard let oldTTY = previousTTYNames[panelId],
                  let newTTY = nextTTYNames[panelId] else {
                return false
            }
            return oldTTY == newTTY
        }
        remotePortScanTTYNames = nextTTYNames
        if nextTTYNames.isEmpty {
            keepPolledRemotePortsUntilTTYScan = false
        }
        updateRemotePortPollingStateLocked()
        publishPortsSnapshotLocked()
    }

    private func kickRemotePortScanLocked(panelId: UUID, reason: PortScanKickReason) {
        guard !isStopping else { return }
        guard daemonReady else { return }
        guard remotePortScanTTYNames[panelId] != nil else { return }
        if remotePortScanBurstActive, remotePortScanActiveReason == .command, reason == .refresh {
            return
        }
        remotePortScanPendingReason = remotePortScanPendingReason?.merged(with: reason) ?? reason
        scheduleRemotePortScanCoalesceLocked()
    }

    private func scheduleRemotePortScanCoalesceLocked() {
        guard !remotePortScanBurstActive else { return }
        guard remotePortScanCoalesceWorkItem == nil else { return }

        let generation = remotePortScanGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.remotePortScanGeneration == generation else { return }
            self.remotePortScanCoalesceWorkItem = nil
            guard let reason = self.remotePortScanPendingReason else { return }
            self.remotePortScanPendingReason = nil
            self.remotePortScanBurstActive = true
            self.remotePortScanActiveReason = reason
            self.runRemotePortScanBurstLocked(index: 0, generation: generation, reason: reason)
        }
        remotePortScanCoalesceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func runRemotePortScanBurstLocked(
        index: Int,
        generation: UInt64,
        reason: PortScanKickReason,
        burstStart: DispatchTime? = nil
    ) {
        guard remotePortScanGeneration == generation else { return }

        let burstOffsets = reason.burstOffsets
        guard index < burstOffsets.count else {
            remotePortScanBurstActive = false
            remotePortScanActiveReason = nil
            if remotePortScanPendingReason != nil && remotePortScanCoalesceWorkItem == nil {
                scheduleRemotePortScanCoalesceLocked()
            }
            return
        }

        let start = burstStart ?? .now()
        let deadline = start + burstOffsets[index]
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            guard self.remotePortScanGeneration == generation else { return }
            self.performRemotePortScanLocked()
            self.runRemotePortScanBurstLocked(
                index: index + 1,
                generation: generation,
                reason: reason,
                burstStart: start
            )
        }
    }

    private func performRemotePortScanLocked() {
        let ttyNamesByPanel = remotePortScanTTYNames
        guard !ttyNamesByPanel.isEmpty else {
            remoteScannedPortsByPanel.removeAll()
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
            return
        }

        do {
            remoteScannedPortsByPanel = try scanRemotePortsByPanelLocked(ttyNamesByPanel: ttyNamesByPanel)
            keepPolledRemotePortsUntilTTYScan = false
            polledRemotePorts = []
            publishPortsSnapshotLocked()
        } catch {
            debugLog("remote.ports.scan.failed error=\(error.localizedDescription) \(debugConfigSummary())")
        }
    }

    private func scanRemotePortsByPanelLocked(ttyNamesByPanel: [UUID: String]) throws -> [UUID: [Int]] {
        let ttyNames = Array(Set(ttyNamesByPanel.values)).sorted()
        guard !ttyNames.isEmpty else { return [:] }

        let command = "sh -c \(Self.shellSingleQuoted(Self.remotePortScanScript(ttyNames: ttyNames, excluding: excludedRemoteScanPorts())))"
        let result = try sshExec(
            arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
            timeout: 8
        )
        guard result.status == 0 else {
            let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
            throw NSError(domain: "cmux.remote.ports", code: 90, userInfo: [
                NSLocalizedDescriptionKey: "remote port scan failed: \(detail)",
            ])
        }

        let portsByTTY = Self.parseRemoteTTYPortPairs(
            output: result.stdout,
            trackedTTYNames: Set(ttyNames)
        )

        return ttyNamesByPanel.reduce(into: [UUID: [Int]]()) { result, entry in
            result[entry.key] = portsByTTY[entry.value] ?? []
        }
    }

    private func startRemotePortPollingLocked(mode: RemotePortPollingMode) {
        if remotePortPollTimer != nil, remotePortPollMode == mode {
            return
        }
        stopRemotePortPollingLocked()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + mode.initialDelay, repeating: mode.repeatInterval)
        timer.setEventHandler { [weak self] in
            self?.pollRemotePortsLocked()
        }
        remotePortPollTimer = timer
        remotePortPollMode = mode
        timer.resume()
        pollRemotePortsLocked()
    }

    private func stopRemotePortPollingLocked() {
        remotePortPollTimer?.setEventHandler {}
        remotePortPollTimer?.cancel()
        remotePortPollTimer = nil
        remotePortPollMode = nil
    }

    private func updateRemotePortPollingStateLocked() {
        guard daemonReady, !isStopping, let pollingMode = remotePortPollingModeLocked() else {
            stopRemotePortPollingLocked()
            if !keepPolledRemotePortsUntilTTYScan {
                polledRemotePorts = []
            }
            remotePortPollBaselinePorts = nil
            return
        }
        startRemotePortPollingLocked(mode: pollingMode)
    }

    private func pollRemotePortsLocked() {
        guard !isStopping else { return }
        guard daemonReady else { return }
        if !remotePortScanTTYNames.isEmpty {
            guard shouldUseTTYFallbackRemotePortPollingLocked() else {
                stopRemotePortPollingLocked()
                if !keepPolledRemotePortsUntilTTYScan {
                    polledRemotePorts = []
                }
                publishPortsSnapshotLocked()
                return
            }
            if remotePortScanBurstActive || remotePortScanCoalesceWorkItem != nil || remotePortScanPendingReason != nil {
                return
            }
            performRemotePortScanLocked()
            return
        }
        guard let pollingMode = remotePortPollingModeLocked() else {
            stopRemotePortPollingLocked()
            polledRemotePorts = []
            remotePortPollBaselinePorts = nil
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
            return
        }
        guard remotePortScanTTYNames.isEmpty else {
            stopRemotePortPollingLocked()
            if !keepPolledRemotePortsUntilTTYScan {
                polledRemotePorts = []
            }
            remotePortPollBaselinePorts = nil
            publishPortsSnapshotLocked()
            return
        }

        let command = "sh -c \(Self.shellSingleQuoted(Self.remoteAllPortsScanScript(excluding: excludedRemoteScanPorts())))"
        do {
            let result = try sshExec(
                arguments: sshCommonArguments(batchMode: true) + [configuration.destination, command],
                timeout: 8
            )
            guard result.status == 0 else {
                let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ?? "ssh exited \(result.status)"
                throw NSError(domain: "cmux.remote.ports", code: 90, userInfo: [
                    NSLocalizedDescriptionKey: "remote port scan failed: \(detail)",
                ])
            }
            let currentPorts = Set(Self.parseRemotePorts(output: result.stdout))
            switch pollingMode {
            case .hostWide:
                polledRemotePorts = currentPorts.sorted()
                remotePortPollBaselinePorts = nil
            case .hostWideDelta:
                if let baselinePorts = remotePortPollBaselinePorts {
                    polledRemotePorts = currentPorts.subtracting(baselinePorts).sorted()
                } else {
                    remotePortPollBaselinePorts = currentPorts
                    polledRemotePorts = []
                }
            case .ttyScoped:
                polledRemotePorts = []
                remotePortPollBaselinePorts = nil
            }
            keepPolledRemotePortsUntilTTYScan = false
            publishPortsSnapshotLocked()
        } catch {
            debugLog("remote.ports.poll.failed error=\(error.localizedDescription) \(debugConfigSummary())")
        }
    }

    private func excludedRemoteScanPorts() -> Set<Int> {
        var excluded: Set<Int> = []
        if let relayPort = configuration.relayPort, relayPort > 0 {
            excluded.insert(relayPort)
        }
        if let configuredPort = configuration.port, configuredPort > 0 {
            excluded.insert(configuredPort)
        }
        return excluded
    }

    private func shouldUseFallbackRemotePortPollingLocked() -> Bool {
        // `cmux ssh` owns the remote shell bootstrap and can report the remote
        // TTY precisely. Falling back to host-wide port scans in that path leaks
        // unrelated listeners from the remote machine into the workspace card.
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return startupCommand?.isEmpty != false
    }

    private func shouldUseTTYFallbackRemotePortPollingLocked() -> Bool {
        // `cmux ssh` can still land in shells without our command hooks, such as
        // `/bin/sh` in the Docker fixture. Once the workspace knows the TTY,
        // keep a low-frequency TTY-scoped poll so unsupported shells still
        // surface ports without bringing back noisy host-wide scans.
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return startupCommand?.isEmpty == false
    }

    private func remotePortPollingModeLocked() -> RemotePortPollingMode? {
        if !remotePortScanTTYNames.isEmpty {
            return shouldUseTTYFallbackRemotePortPollingLocked() ? .ttyScoped : nil
        }
        let startupCommand = configuration.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if startupCommand?.isEmpty == false {
            return .hostWideDelta
        }
        return shouldUseFallbackRemotePortPollingLocked() ? .hostWide : nil
    }

    private static func parseRemoteTTYPortPairs(output: String, trackedTTYNames: Set<String>) -> [String: [Int]] {
        var portsByTTY = Dictionary(uniqueKeysWithValues: trackedTTYNames.map { ($0, Set<Int>()) })

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let ttyName = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard trackedTTYNames.contains(ttyName),
                  let port = Int(parts[1]),
                  port >= 1024,
                  port <= 65535 else {
                continue
            }
            portsByTTY[ttyName, default: []].insert(port)
        }

        return portsByTTY.reduce(into: [String: [Int]]()) { result, entry in
            result[entry.key] = entry.value.sorted()
        }
    }

    private static func parseRemotePorts(output: String) -> [Int] {
        let values = output
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
            .filter { $0 >= 1024 && $0 <= 65535 }
        return Array(Set(values)).sorted()
    }

    private static func normalizedRemotePortScanTTYName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard !candidate.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return candidate
    }

    private static func remotePortScanScript(ttyNames: [String], excluding ports: Set<Int>) -> String {
        let ttySet = ttyNames.joined(separator: " ")
        let ttyCSV = ttyNames.joined(separator: ",")
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        cmux_tracked_ttys=" \(ttySet) "
        cmux_tty_csv='\(ttyCSV)'
        cmux_excluded_ports=" \(excludedPorts) "

        cmux_emit_port() {
          cmux_tty="$1"
          cmux_port="$2"
          case "$cmux_tracked_ttys" in
            *" $cmux_tty "*) ;;
            *) return 0 ;;
          esac
          case "$cmux_excluded_ports" in
            *" $cmux_port "*) return 0 ;;
          esac
          [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
          printf '%s\\t%s\\n' "$cmux_tty" "$cmux_port"
        }

        cmux_used_ss=0
        if [ -d /proc ] && command -v ss >/dev/null 2>&1; then
          cmux_ss_output="$(ss -ltnpH 2>/dev/null || true)"
          case "$cmux_ss_output" in
            *pid=*)
              cmux_used_ss=1
              printf '%s\\n' "$cmux_ss_output" | while IFS= read -r cmux_line; do
                [ -n "$cmux_line" ] || continue
                cmux_port="$(printf '%s\\n' "$cmux_line" | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ { print $1; exit }')"
                [ -n "$cmux_port" ] || continue
                printf '%s\\n' "$cmux_line" | awk '
                  {
                    line = $0
                    while (match(line, /pid=[0-9]+/)) {
                      print substr(line, RSTART + 4, RLENGTH - 4)
                      line = substr(line, RSTART + RLENGTH)
                    }
                  }
                ' | while IFS= read -r cmux_pid; do
                  [ -n "$cmux_pid" ] || continue
                  cmux_tty_path="$(readlink "/proc/$cmux_pid/fd/0" 2>/dev/null || true)"
                  [ -n "$cmux_tty_path" ] || continue
                  cmux_tty="${cmux_tty_path##*/}"
                  [ -n "$cmux_tty" ] || continue
                  cmux_emit_port "$cmux_tty" "$cmux_port"
                done
              done
              ;;
          esac
        fi

        if [ "$cmux_used_ss" -eq 0 ] && command -v lsof >/dev/null 2>&1 && [ -n "$cmux_tty_csv" ]; then
          cmux_tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t cmux-ports)"
          trap 'rm -rf "$cmux_tmpdir"' EXIT INT TERM
          cmux_pid_tty_map="$cmux_tmpdir/pid_tty"
          ps -t "$cmux_tty_csv" -o pid=,tty= 2>/dev/null | awk '
            NF >= 2 {
              tty = $2
              sub(/^.*\\//, "", tty)
              print $1 "\\t" tty
            }
          ' > "$cmux_pid_tty_map"
          [ -s "$cmux_pid_tty_map" ] || exit 0
          cmux_pid_csv="$(awk '{print $1}' "$cmux_pid_tty_map" | paste -sd, -)"
          [ -n "$cmux_pid_csv" ] || exit 0
          lsof -nP -a -p "$cmux_pid_csv" -iTCP -sTCP:LISTEN -Fpn 2>/dev/null | awk -v map="$cmux_pid_tty_map" '
            BEGIN {
              while ((getline < map) > 0) {
                pid_to_tty[$1] = $2
              }
              close(map)
            }
            $0 ~ /^p/ {
              pid = substr($0, 2)
              tty = pid_to_tty[pid]
              next
            }
            $0 ~ /^n/ && tty != "" {
              name = substr($0, 2)
              sub(/->.*/, "", name)
              sub(/^.*:/, "", name)
              sub(/[^0-9].*/, "", name)
              if (name != "") {
                print tty "\\t" name
              }
            }
          ' | while IFS=$'\\t' read -r cmux_tty cmux_port; do
            [ -n "$cmux_tty" ] || continue
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_tty" "$cmux_port"
          done
        fi
        """
    }

    private static func remoteAllPortsScanScript(excluding ports: Set<Int>) -> String {
        let excludedPorts = ports.sorted().map(String.init).joined(separator: " ")

        return """
        set -eu
        cmux_excluded_ports=" \(excludedPorts) "

        cmux_emit_port() {
          cmux_port="$1"
          case "$cmux_excluded_ports" in
            *" $cmux_port "*) return 0 ;;
          esac
          [ "$cmux_port" -ge 1024 ] && [ "$cmux_port" -le 65535 ] || return 0
          printf '%s\\n' "$cmux_port"
        }

        if command -v ss >/dev/null 2>&1; then
          ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        elif command -v netstat >/dev/null 2>&1; then
          netstat -lnt 2>/dev/null | awk 'NR > 2 {print $4}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        elif command -v lsof >/dev/null 2>&1; then
          lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sed -E 's/.*:([0-9]+)$/\\1/' | awk '/^[0-9]+$/ {print $1}' | while IFS= read -r cmux_port; do
            [ -n "$cmux_port" ] || continue
            cmux_emit_port "$cmux_port"
          done
        fi
        """
    }

}

enum SidebarLogLevel: String {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry: Equatable {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState: Equatable {
    let value: Double
    let label: String?
}

struct SidebarGitBranchState: Equatable {
    let branch: String
    let isDirty: Bool
}

private struct SidebarPanelObservationState: Equatable {
    let panelIds: [UUID]

    init(panels: [UUID: any Panel]) {
        panelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

enum WorkspaceRemoteConnectionState: String {
    case disconnected
    case connecting
    case connected
    case error
}

enum WorkspaceRemoteDaemonState: String {
    case unavailable
    case bootstrapping
    case ready
    case error
}

struct WorkspaceRemoteDaemonStatus: Equatable {
    var state: WorkspaceRemoteDaemonState = .unavailable
    var detail: String?
    var version: String?
    var name: String?
    var capabilities: [String] = []
    var remotePath: String?

    func payload() -> [String: Any] {
        [
            "state": state.rawValue,
            "detail": detail ?? NSNull(),
            "version": version ?? NSNull(),
            "name": name ?? NSNull(),
            "capabilities": capabilities,
            "remote_path": remotePath ?? NSNull(),
        ]
    }
}

struct WorkspaceRemoteConfiguration: Equatable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    let localProxyPort: Int?
    let relayPort: Int?
    let relayID: String?
    let relayToken: String?
    let localSocketPath: String?
    let terminalStartupCommand: String?
    let foregroundAuthToken: String?

    init(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        localProxyPort: Int?,
        relayPort: Int?,
        relayID: String?,
        relayToken: String?,
        localSocketPath: String?,
        terminalStartupCommand: String?,
        foregroundAuthToken: String? = nil
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.localProxyPort = localProxyPort
        self.relayPort = relayPort
        self.relayID = relayID
        self.relayToken = relayToken
        self.localSocketPath = localSocketPath
        self.terminalStartupCommand = terminalStartupCommand
        self.foregroundAuthToken = foregroundAuthToken
    }

    var displayTarget: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }

    var proxyBrokerTransportKey: String {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.map(String.init) ?? ""
        let normalizedIdentity = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedLocalProxyPort = localProxyPort.map(String.init) ?? ""
        let normalizedOptions = Self.proxyBrokerSSHOptions(sshOptions).joined(separator: "\u{1f}")
        return [normalizedDestination, normalizedPort, normalizedIdentity, normalizedOptions, normalizedLocalProxyPort]
            .joined(separator: "\u{1e}")
    }

    private static func proxyBrokerSSHOptions(_ options: [String]) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }.filter { option in
            proxyBrokerSSHOptionKey(option) != "controlpath"
        }
    }

    private static func proxyBrokerSSHOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }
}

enum SidebarPullRequestStatus: String {
    case open
    case merged
    case closed
}

private func normalizedSidebarBranchName(_ branch: String?) -> String? {
    guard let branch else { return nil }
    let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

struct SidebarPullRequestState: Equatable {
    let number: Int
    let label: String
    let url: URL
    let status: SidebarPullRequestStatus
    let branch: String?
    let isStale: Bool

    init(
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        isStale: Bool = false
    ) {
        self.number = number
        self.label = label
        self.url = url
        self.status = status
        self.branch = normalizedSidebarBranchName(branch)
        self.isStale = isStale
    }
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

    fileprivate static func normalizedDirectory(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func relativePathFromTilde(_ directory: String) -> String? {
        let normalized = normalizedDirectory(directory)
        switch normalized {
        case "~":
            return ""
        case let path? where path.hasPrefix("~/"):
            return String(path.dropFirst(2))
        default:
            return nil
        }
    }

    private static func commonHomeDirectoryPrefix(from absoluteDirectory: String) -> String? {
        guard let normalized = normalizedDirectory(absoluteDirectory) else { return nil }
        let standardized = NSString(string: normalized).standardizingPath
        if standardized == "/root" || standardized.hasPrefix("/root/") {
            return "/root"
        }

        let components = NSString(string: standardized).pathComponents
        if components.count >= 3, components[0] == "/", components[1] == "Users" {
            return NSString.path(withComponents: Array(components.prefix(3)))
        }
        if components.count >= 3, components[0] == "/", components[1] == "home" {
            return NSString.path(withComponents: Array(components.prefix(3)))
        }
        if components.count >= 4, components[0] == "/", components[1] == "var", components[2] == "home" {
            return NSString.path(withComponents: Array(components.prefix(4)))
        }

        return nil
    }

    private static func inferredHomeDirectory(
        matchingTildeDirectory tildeDirectory: String,
        absoluteDirectory: String
    ) -> String? {
        guard let relativePath = relativePathFromTilde(tildeDirectory),
              let normalizedAbsolute = normalizedDirectory(absoluteDirectory) else { return nil }
        let standardizedAbsolute = NSString(string: normalizedAbsolute).standardizingPath
        let homeDirectory: String
        if relativePath.isEmpty {
            homeDirectory = standardizedAbsolute
        } else {
            let suffix = "/" + relativePath
            guard standardizedAbsolute.hasSuffix(suffix) else { return nil }
            homeDirectory = String(standardizedAbsolute.dropLast(suffix.count))
        }

        guard commonHomeDirectoryPrefix(from: homeDirectory) == homeDirectory else { return nil }
        return homeDirectory
    }

    fileprivate static func inferredRemoteHomeDirectory(
        from directories: [String],
        fallbackDirectory: String?
    ) -> String? {
        let candidates = directories + [fallbackDirectory].compactMap { $0 }
        let tildeDirectories = candidates.compactMap { directory -> String? in
            guard let normalized = normalizedDirectory(directory),
                  relativePathFromTilde(normalized) != nil else { return nil }
            return normalized
        }
        let absoluteDirectories = candidates.compactMap { directory -> String? in
            guard let normalized = normalizedDirectory(directory), normalized.hasPrefix("/") else { return nil }
            return NSString(string: normalized).standardizingPath
        }

        let inferredHomes = Set(
            tildeDirectories.flatMap { tildeDirectory in
                absoluteDirectories.compactMap { absoluteDirectory in
                    inferredHomeDirectory(
                        matchingTildeDirectory: tildeDirectory,
                        absoluteDirectory: absoluteDirectory
                    )
                }
            }
        )

        if inferredHomes.count == 1 {
            return inferredHomes.first
        }
        if !inferredHomes.isEmpty {
            return nil
        }

        return absoluteDirectories.lazy.compactMap(commonHomeDirectoryPrefix(from:)).first
    }

    private static func expandedTildePath(
        _ directory: String,
        homeDirectoryForTildeExpansion: String?
    ) -> String {
        guard let relativePath = relativePathFromTilde(directory),
              let homeDirectory = normalizedDirectory(homeDirectoryForTildeExpansion) else {
            return directory
        }
        if relativePath.isEmpty {
            return homeDirectory
        }
        return NSString(string: homeDirectory).appendingPathComponent(relativePath)
    }

    fileprivate static func canonicalDirectoryKey(
        _ directory: String?,
        homeDirectoryForTildeExpansion: String?
    ) -> String? {
        guard let directory = normalizedDirectory(directory) else { return nil }
        let expanded = expandedTildePath(
            directory,
            homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
        )
        let standardized = NSString(string: expanded).standardizingPath
        let cleaned = standardized.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func preferredDisplayedDirectory(
        existing: String?,
        replacement: String?,
        homeDirectoryForTildeExpansion: String?
    ) -> String? {
        guard let replacement = normalizedDirectory(replacement) else { return existing }
        guard let existing = normalizedDirectory(existing) else { return replacement }

        let existingUsesTilde = relativePathFromTilde(existing) != nil
        let replacementUsesTilde = relativePathFromTilde(replacement) != nil
        if existingUsesTilde != replacementUsesTilde {
            return replacementUsesTilde ? existing : replacement
        }

        if canonicalDirectoryKey(existing, homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion)
            == canonicalDirectoryKey(
                replacement,
                homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
            ) {
            return existing
        }

        return replacement
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

    static func orderedUniquePullRequests(
        orderedPanelIds: [UUID],
        panelPullRequests: [UUID: SidebarPullRequestState],
        fallbackPullRequest: SidebarPullRequestState?
    ) -> [SidebarPullRequestState] {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .merged: return 3
            case .open: return 2
            case .closed: return 1
            }
        }

        func freshnessPriority(_ isStale: Bool) -> Int {
            isStale ? 0 : 1
        }

        func normalizedReviewURLKey(for url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }

            // Treat URL variants that differ only by query/fragment as the same review item.
            components.query = nil
            components.fragment = nil
            let scheme = components.scheme?.lowercased() ?? ""
            let host = components.host?.lowercased() ?? ""
            let port = components.port.map { ":\($0)" } ?? ""
            var path = components.path
            if path.hasSuffix("/"), path.count > 1 {
                path.removeLast()
            }
            return "\(scheme)://\(host)\(port)\(path)"
        }

        func reviewKey(for state: SidebarPullRequestState) -> String {
            "\(state.label.lowercased())#\(state.number)|\(normalizedReviewURLKey(for: state.url))"
        }

        var orderedKeys: [String] = []
        var pullRequestsByKey: [String: SidebarPullRequestState] = [:]

        for panelId in orderedPanelIds {
            guard let state = panelPullRequests[panelId] else { continue }
            let key = reviewKey(for: state)
            if pullRequestsByKey[key] == nil {
                orderedKeys.append(key)
                pullRequestsByKey[key] = state
                continue
            }
            guard let existing = pullRequestsByKey[key] else { continue }
            if freshnessPriority(state.isStale) > freshnessPriority(existing.isStale) {
                pullRequestsByKey[key] = state
            } else if freshnessPriority(state.isStale) == freshnessPriority(existing.isStale),
                      statusPriority(state.status) > statusPriority(existing.status) {
                pullRequestsByKey[key] = state
            }
        }

        if orderedKeys.isEmpty, let fallbackPullRequest {
            return [fallbackPullRequest]
        }

        return orderedKeys.compactMap { pullRequestsByKey[$0] }
    }

    static func orderedUniqueBranchDirectoryEntries(
        orderedPanelIds: [UUID],
        panelBranches: [UUID: SidebarGitBranchState],
        panelDirectories: [UUID: String],
        defaultDirectory: String?,
        homeDirectoryForTildeExpansion: String?,
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

        let normalized = normalizedDirectory
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
            let directory = normalized(panelDirectories[panelId])
            guard branch != nil || directory != nil else { continue }

            let panelDirty = panelBranch != nil
                ? (panelBranches[panelId]?.isDirty ?? false)
                : defaultBranchDirty

            let key: EntryKey
            if let directoryKey = canonicalDirectoryKey(
                directory,
                homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
            ) {
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
                    existing.directory = preferredDisplayedDirectory(
                        existing: existing.directory,
                        replacement: directory,
                        homeDirectoryForTildeExpansion: homeDirectoryForTildeExpansion
                    )
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
    let profileID: UUID?
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
    static let terminalScrollBarHiddenDidChangeNotification = Notification.Name(
        "cmux.workspaceTerminalScrollBarHiddenDidChange"
    )

    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var customDescription: String?
    @Published var isPinned: Bool = false
    @Published var customColor: String?  // hex string, e.g. "#C0392B"
    @Published private(set) var terminalScrollBarHidden: Bool = false
    @Published var currentDirectory: String
    private(set) var preferredBrowserProfileID: UUID?

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
    private var debugStressPreloadSelectionDepth = 0

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
    weak var owningTabManager: TabManager?


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

    func effectiveSelectedPanelId(inPane paneId: PaneID) -> UUID? {
        bonsplitController.selectedTab(inPane: paneId).flatMap { panelIdFromSurfaceId($0.id) }
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
    @Published private(set) var tmuxLayoutSnapshot: LayoutSnapshot?
    @Published private(set) var tmuxWorkspaceFlashPanelId: UUID?
    @Published private(set) var tmuxWorkspaceFlashReason: WorkspaceAttentionFlashReason?
    @Published private(set) var tmuxWorkspaceFlashToken: UInt64 = 0
    private var manualUnreadMarkedAt: [UUID: Date] = [:]
    nonisolated private static let manualUnreadFocusGraceInterval: TimeInterval = 0.2
    nonisolated private static let manualUnreadClearDelayAfterFocusFlash: TimeInterval = 0.2
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var metadataBlocks: [String: SidebarMetadataBlock] = [:]
    @Published var logEntries: [SidebarLogEntry] = []
    @Published var progress: SidebarProgressState?
    @Published var gitBranch: SidebarGitBranchState?
    @Published var panelGitBranches: [UUID: SidebarGitBranchState] = [:]
    @Published var pullRequest: SidebarPullRequestState?
    @Published var panelPullRequests: [UUID: SidebarPullRequestState] = [:]
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    var agentListeningPorts: [Int] = []
    @Published var remoteConfiguration: WorkspaceRemoteConfiguration?
    @Published var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected
    @Published var remoteConnectionDetail: String?
    @Published var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus()
    @Published var remoteDetectedPorts: [Int] = []
    @Published var remoteForwardedPorts: [Int] = []
    @Published var remotePortConflicts: [Int] = []
    @Published var remoteProxyEndpoint: BrowserProxyEndpoint?
    @Published var remoteHeartbeatCount: Int = 0
    @Published var remoteLastHeartbeatAt: Date?
    @Published var listeningPorts: [Int] = []
    @Published private(set) var activeRemoteTerminalSessionCount: Int = 0
    var surfaceTTYNames: [UUID: String] = [:]
    private var remoteSessionController: WorkspaceRemoteSessionController?
    private var pendingRemoteForegroundAuthToken: String?
    fileprivate var activeRemoteSessionControllerID: UUID?
    private var remoteLastErrorFingerprint: String?
    private var remoteLastDaemonErrorFingerprint: String?
    private var remoteLastPortConflictFingerprint: String?
    private var remoteDetectedSurfaceIds: Set<UUID> = []
    private var activeRemoteTerminalSurfaceIds: Set<UUID> = []
    private var pendingRemoteTerminalChildExitSurfaceIds: Set<UUID> = []

    private static let remoteErrorStatusKey = "remote.error"
    private static let remotePortConflictStatusKey = "remote.port_conflicts"
    private static let remoteNotificationCooldown: TimeInterval = 5 * 60
    private static let sshControlMasterCleanupQueue = DispatchQueue(
        label: "com.cmux.remote-ssh.control-master-cleanup",
        qos: .utility
    )
    private static let remoteHeartbeatDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static var runSSHControlMasterCommandOverrideForTesting: (([String]) -> Void)?
    private var panelShellActivityStates: [UUID: PanelShellActivityState] = [:]
    /// PIDs associated with agent status entries (e.g. claude_code), keyed by status key.
    /// Used for stale-session detection: if the PID is dead, the status entry is cleared.
    var agentPIDs: [String: pid_t] = [:]
    private var restoredTerminalScrollbackByPanelId: [UUID: String] = [:]

    private func sidebarObservationSignal<Value: Equatable>(
        _ publisher: Published<Value>.Publisher
    ) -> AnyPublisher<Void, Never> {
        publisher
            .dropFirst()
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    lazy var sidebarImmediateObservationPublisher: AnyPublisher<Void, Never> = {
        let publishers: [AnyPublisher<Void, Never>] = [
            sidebarObservationSignal($title),
            sidebarObservationSignal($customDescription),
            sidebarObservationSignal($isPinned),
            sidebarObservationSignal($customColor),
            sidebarObservationSignal($terminalScrollBarHidden),
        ]

        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }()

    lazy var sidebarObservationPublisher: AnyPublisher<Void, Never> = {
        let publishers: [AnyPublisher<Void, Never>] = [
            sidebarObservationSignal($currentDirectory),
            $panels
                .map(SidebarPanelObservationState.init)
                .dropFirst()
                .removeDuplicates()
                .map { _ in () }
                .eraseToAnyPublisher(),
            sidebarObservationSignal($panelDirectories),
            sidebarObservationSignal($statusEntries),
            sidebarObservationSignal($metadataBlocks),
            sidebarObservationSignal($logEntries),
            sidebarObservationSignal($progress),
            sidebarObservationSignal($gitBranch),
            sidebarObservationSignal($panelGitBranches),
            sidebarObservationSignal($pullRequest),
            sidebarObservationSignal($panelPullRequests),
            sidebarObservationSignal($remoteConfiguration),
            sidebarObservationSignal($remoteConnectionState),
            sidebarObservationSignal($remoteConnectionDetail),
            sidebarObservationSignal($activeRemoteTerminalSessionCount),
            sidebarObservationSignal($listeningPorts),
        ]

        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }()

    private static func isProxyOnlyRemoteError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote proxy")
            || lowered.contains("proxy_unavailable")
            || lowered.contains("local daemon proxy")
            || lowered.contains("proxy failure")
            || lowered.contains("daemon transport")
    }

    private var preservesSSHTerminalConnection: Bool {
        activeRemoteTerminalSessionCount > 0
            && remoteConfiguration?.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var hasProxyOnlyRemoteSidebarError: Bool {
        guard let entry = statusEntries[Self.remoteErrorStatusKey]?.value else { return false }
        return entry.lowercased().contains("remote proxy unavailable")
    }

    private func remoteNotificationCooldownKey(target: String) -> String? {
        let rawTarget = (remoteConfiguration?.destination ?? target)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTarget.isEmpty else { return nil }
        let normalizedHost = rawTarget
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedHost, !normalizedHost.isEmpty else { return nil }
        return "remote-host:\(normalizedHost)"
    }

    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    private var processTitle: String

    private enum SurfaceKind {
        static let terminal = "terminal"
        static let browser = "browser"
        static let markdown = "markdown"
    }

    enum PanelShellActivityState: String {
        case unknown
        case promptIdle
        case commandRunning
    }

    nonisolated static func resolveCloseConfirmation(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        switch shellActivityState ?? .unknown {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
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
        bonsplitAppearance(
            from: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            tabTitleFontSize: config.surfaceTabBarFontSize
        )
    }

    static func bonsplitChromeHex(backgroundColor: NSColor, backgroundOpacity: Double) -> String {
        let themedColor = GhosttyBackgroundTheme.color(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        let includeAlpha = themedColor.alphaComponent < 0.999
        return themedColor.hexString(includeAlpha: includeAlpha)
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        .init(backgroundHex: backgroundColor.hexString())
    }

    private static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double,
        tabTitleFontSize: CGFloat = 11
    ) -> BonsplitConfiguration.Appearance {
        BonsplitConfiguration.Appearance(
            tabTitleFontSize: tabTitleFontSize,
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: .init(
                backgroundHex: Self.bonsplitChromeHex(
                    backgroundColor: backgroundColor,
                    backgroundOpacity: backgroundOpacity
                )
            )
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        let nextHex = Self.bonsplitChromeHex(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity
        )
        let nextTabTitleFontSize = config.surfaceTabBarFontSize
        let currentAppearance = bonsplitController.configuration.appearance
        let currentBackgroundHex = currentAppearance.chromeColors.backgroundHex
        let currentTabTitleFontSize = currentAppearance.tabTitleFontSize
        let backgroundChanged = currentBackgroundHex != nextHex
        let fontSizeChanged = abs(currentTabTitleFontSize - nextTabTitleFontSize) > 0.0001
        let isNoOp = !backgroundChanged && !fontSizeChanged

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) " +
                "currentBg=\(currentBackgroundHex ?? "nil") nextBg=\(nextHex) " +
                "currentTabFont=\(String(format: "%.3f", currentTabTitleFontSize)) " +
                "nextTabFont=\(String(format: "%.3f", nextTabTitleFontSize)) noop=\(isNoOp)"
            )
        }

        guard !isNoOp else { return }

        if backgroundChanged {
            bonsplitController.configuration.appearance.chromeColors.backgroundHex = nextHex
        }
        if fontSizeChanged {
            bonsplitController.configuration.appearance.tabTitleFontSize = nextTabTitleFontSize
        }

        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) " +
                "resultingBg=\(bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil") " +
                "resultingTabFont=\(String(format: "%.3f", bonsplitController.configuration.appearance.tabTitleFontSize))"
            )
        }
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        let nextHex = Self.bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let isNoOp = currentChromeColors.backgroundHex == nextHex

        if GhosttyApp.shared.backgroundLogEnabled {
            let currentBackgroundHex = currentChromeColors.backgroundHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) currentBg=\(currentBackgroundHex) nextBg=\(nextHex) noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }
        bonsplitController.configuration.appearance.chromeColors.backgroundHex = nextHex
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) resultingBg=\(bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil")"
            )
        }
    }

    init(
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:]
    ) {
        self.id = UUID()
        self.portOrdinal = portOrdinal
        self.processTitle = title
        self.title = title
        self.customTitle = nil
        self.customDescription = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // and keep split entry instantaneous.
        // Use the cached Ghostty config so new workspaces inherit tab-strip sizing
        // without paying repeated parse costs on the workspace-creation hot path.
        let initialSurfaceTabBarFontSize = GhosttyConfig.load().surfaceTabBarFontSize
        let appearance = Self.bonsplitAppearance(
            from: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            tabTitleFontSize: initialSurfaceTabBarFontSize
        )
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
        bonsplitController.contextMenuShortcuts = Self.buildContextMenuShortcuts()

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // Create initial terminal panel
        let terminalPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: configTemplate,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil,
            portOrdinal: portOrdinal,
            initialCommand: initialTerminalCommand,
            initialInput: initialTerminalInput,
            initialEnvironmentOverrides: initialTerminalEnvironment
        )
        configureTerminalPanel(terminalPanel)
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
        bonsplitController.onTabCloseRequest = { [weak self] tabId, _ in
            self?.markExplicitClose(surfaceId: tabId)
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
        tmuxLayoutSnapshot = bonsplitController.layoutSnapshot()
    }

    deinit {
        activeRemoteSessionControllerID = nil
        remoteSessionController?.stop()
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

    /// Tab IDs whose next close attempt should be treated as an explicit
    /// workspace-close gesture from the user (the tab-strip X button, or Cmd+W when
    /// the shortcut preference is set to close the workspace on the last surface),
    /// rather than an internal close/move flow.
    private var explicitUserCloseTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    /// Keyed by the closing tab ID, value is the tab ID we want to select next.
    private var postCloseSelectTabId: [TabID: TabID] = [:]
    /// Panel IDs that were in a pane when a pane-close operation was approved.
    /// Bonsplit pane-close does not emit per-tab didClose callbacks.
    private var pendingPaneClosePanelIds: [UUID: [UUID]] = [:]
    private var pendingClosedBrowserRestoreSnapshots: [TabID: ClosedBrowserPanelRestoreSnapshot] = [:]
    private var isApplyingTabSelection = false
    private struct PendingTabSelectionRequest {
        let tabId: TabID
        let pane: PaneID
        let reassertAppKitFocus: Bool
        let focusIntent: PanelFocusIntent?
        let previousTerminalHostedView: GhosttySurfaceScrollView?
    }
    private var pendingTabSelection: PendingTabSelectionRequest?
    private var isReconcilingFocusState = false
    private var focusReconcileScheduled = false
#if DEBUG
    private(set) var debugFocusReconcileScheduledDuringDetachCount: Int = 0
    private var debugLastDidMoveTabTimestamp: TimeInterval = 0
    private var debugDidMoveTabEventCount: UInt64 = 0
#endif
    private var layoutFollowUpObservers: [NSObjectProtocol] = []
    private var layoutFollowUpPanelsCancellable: AnyCancellable?
    private var layoutFollowUpTimeoutWorkItem: DispatchWorkItem?
    private var layoutFollowUpReason: String?
    private var layoutFollowUpTerminalFocusPanelId: UUID?
    private var layoutFollowUpBrowserPanelId: UUID?
    private var layoutFollowUpBrowserExitFocusPanelId: UUID?
    private var layoutFollowUpNeedsGeometryPass = false
    private var layoutFollowUpAttemptScheduled = false
    private var layoutFollowUpAttemptVersion: Int = 0
    private var layoutFollowUpStalledAttemptCount = 0
    private var isAttemptingLayoutFollowUp = false
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
        let ttyName: String?
        let cachedTitle: String?
        let customTitle: String?
        let manuallyUnread: Bool
        let isRemoteTerminal: Bool
        let remoteRelayPort: Int?
        let remoteCleanupConfiguration: WorkspaceRemoteConfiguration?

        func withRemoteCleanupConfiguration(_ configuration: WorkspaceRemoteConfiguration?) -> Self {
            Self(
                panelId: panelId,
                panel: panel,
                title: title,
                icon: icon,
                iconImageData: iconImageData,
                kind: kind,
                isLoading: isLoading,
                isPinned: isPinned,
                directory: directory,
                ttyName: ttyName,
                cachedTitle: cachedTitle,
                customTitle: customTitle,
                manuallyUnread: manuallyUnread,
                isRemoteTerminal: isRemoteTerminal,
                remoteRelayPort: remoteRelayPort,
                remoteCleanupConfiguration: configuration
            )
        }
    }

    private var detachingTabIds: Set<TabID> = []
    private var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] = [:]
    private var activeDetachCloseTransactions: Int = 0
    private var isDetachingCloseTransaction: Bool { activeDetachCloseTransactions > 0 }
    private var pendingRemoteSurfaceTTYName: String?
    private var pendingRemoteSurfaceTTYSurfaceId: UUID?
    private var pendingRemoteSurfacePortKickReason: WorkspaceRemoteSessionController.PortScanKickReason?
    private var pendingRemoteSurfacePortKickSurfaceId: UUID?
    // When the last live remote terminal is detached out, the source workspace may be
    // closed immediately after the move succeeds. That teardown must not shut down the
    // shared SSH control master that is still serving the moved terminal.
    private var skipControlMasterCleanupAfterDetachedRemoteTransfer = false
    private var transferredRemoteCleanupConfigurationsByPanelId: [UUID: WorkspaceRemoteConfiguration] = [:]

#if DEBUG
    private func debugElapsedMs(since start: TimeInterval) -> String {
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return String(format: "%.2f", ms)
    }
#endif

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    func markExplicitClose(surfaceId: TabID) {
        explicitUserCloseTabIds.insert(surfaceId)
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
    }

    private func configureTerminalPanel(_ terminalPanel: TerminalPanel) {
        terminalPanel.onRequestWorkspacePaneFlash = { [weak self, weak terminalPanel] reason in
            guard let self, let terminalPanel else { return }
            self.triggerWorkspacePaneFlash(panelId: terminalPanel.id, reason: reason)
        }
    }

    private func triggerWorkspacePaneFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        tmuxWorkspaceFlashPanelId = panelId
        tmuxWorkspaceFlashReason = reason
        tmuxWorkspaceFlashToken &+= 1
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
        setPreferredBrowserProfileID(browserPanel.profileID)
    }

    func setPreferredBrowserProfileID(_ profileID: UUID?) {
        guard let profileID else {
            preferredBrowserProfileID = nil
            return
        }
        guard BrowserProfileStore.shared.profileDefinition(id: profileID) != nil else { return }
        preferredBrowserProfileID = profileID
    }

    private func resolvedNewBrowserProfileID(
        preferredProfileID: UUID? = nil,
        sourcePanelId: UUID? = nil
    ) -> UUID {
        if let preferredProfileID,
           BrowserProfileStore.shared.profileDefinition(id: preferredProfileID) != nil {
            return preferredProfileID
        }
        if let sourcePanelId,
           let sourceBrowserPanel = browserPanel(for: sourcePanelId),
           BrowserProfileStore.shared.profileDefinition(id: sourceBrowserPanel.profileID) != nil {
            return sourceBrowserPanel.profileID
        }
        if let preferredBrowserProfileID,
           BrowserProfileStore.shared.profileDefinition(id: preferredBrowserProfileID) != nil {
            return preferredBrowserProfileID
        }
        return BrowserProfileStore.shared.effectiveLastUsedProfileID
    }

    private func installMarkdownPanelSubscription(_ markdownPanel: MarkdownPanel) {
        let subscription = markdownPanel.$displayTitle
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak markdownPanel] newTitle in
                guard let self,
                      let markdownPanel,
                      let tabId = self.surfaceIdFromPanelId(markdownPanel.id) else { return }
                guard let existing = self.bonsplitController.tab(tabId) else { return }

                if self.panelTitles[markdownPanel.id] != newTitle {
                    self.panelTitles[markdownPanel.id] = newTitle
                }
                let resolvedTitle = self.resolvedPanelTitle(panelId: markdownPanel.id, fallback: newTitle)
                guard existing.title != resolvedTitle else { return }
                self.bonsplitController.updateTab(
                    tabId,
                    title: resolvedTitle,
                    hasCustomTitle: self.panelCustomTitles[markdownPanel.id] != nil
                )
            }
        panelSubscriptions[markdownPanel.id] = subscription
    }

    private func browserRemoteWorkspaceStatusSnapshot() -> BrowserRemoteWorkspaceStatus? {
        guard let target = remoteDisplayTarget else { return nil }
        return BrowserRemoteWorkspaceStatus(
            target: target,
            connectionState: remoteConnectionState,
            heartbeatCount: remoteHeartbeatCount,
            lastHeartbeatAt: remoteLastHeartbeatAt
        )
    }

    private func applyBrowserRemoteWorkspaceStatusToPanels() {
        let snapshot = browserRemoteWorkspaceStatusSnapshot()
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteWorkspaceStatus(snapshot)
        }
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

    func markdownPanel(for panelId: UUID) -> MarkdownPanel? {
        panels[panelId] as? MarkdownPanel
    }

    private func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal
        case .browser:
            return SurfaceKind.browser
        case .markdown:
            return SurfaceKind.markdown
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
        AppDelegate.shared?.notificationStore?.hasVisibleNotificationIndicator(forTabId: id, surfaceId: panelId) ?? false
    }

    private func attentionPersistentState() -> WorkspaceAttentionPersistentState {
        let notificationStore = AppDelegate.shared?.notificationStore
        let unreadPanelIDs = Set(
            panels.keys.filter {
                notificationStore?.hasUnreadNotification(forTabId: id, surfaceId: $0) ?? false
            }
        )
        return WorkspaceAttentionPersistentState(
            unreadPanelIDs: unreadPanelIDs,
            focusedReadPanelID: notificationStore?.focusedReadIndicatorSurfaceId(forTabId: id),
            manualUnreadPanelIDs: manualUnreadPanelIds
        )
    }

    private func requestAttentionFlash(panelId: UUID, reason: WorkspaceAttentionFlashReason) {
        let decision = WorkspaceAttentionCoordinator.decideFlash(
            targetPanelID: panelId,
            reason: reason,
            persistentState: attentionPersistentState()
        )
        guard decision.isAllowed else { return }
        panels[panelId]?.triggerFlash(reason: reason)
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

    func requestBackgroundTerminalSurfaceStartIfNeeded() {
        for terminalPanel in panels.values.compactMap({ $0 as? TerminalPanel }) {
            terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        }
    }

    @discardableResult
    func preloadTerminalPanelForDebugStress(
        tabId: TabID,
        inPane paneId: PaneID
    ) -> TerminalPanel? {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let terminalPanel = panels[panelId] as? TerminalPanel else {
            return nil
        }

        debugStressPreloadSelectionDepth += 1
        defer { debugStressPreloadSelectionDepth -= 1 }
        let isVisibleSelection =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId &&
            terminalPanel.hostedView.window != nil &&
            terminalPanel.hostedView.superview != nil

        if isVisibleSelection {
            terminalPanel.requestViewReattach()
            scheduleTerminalGeometryReconcile()
        }
        terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
        return terminalPanel
    }

    func scheduleDebugStressTerminalGeometryReconcile() {
        scheduleTerminalGeometryReconcile()
    }

    func hasLoadedTerminalSurface() -> Bool {
        let terminalPanels = panels.values.compactMap { $0 as? TerminalPanel }
        guard !terminalPanels.isEmpty else { return true }
        return terminalPanels.contains { $0.surface.surface != nil }
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

    var hasCustomDescription: Bool {
        Self.normalizedCustomDescription(customDescription) != nil
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

    func setTerminalScrollBarHidden(_ hidden: Bool) {
        guard terminalScrollBarHidden != hidden else { return }
        terminalScrollBarHidden = hidden
        NotificationCenter.default.post(
            name: Self.terminalScrollBarHiddenDidChangeNotification,
            object: self
        )
    }

    private static func normalizedCustomDescription(_ description: String?) -> String? {
        let normalizedLineEndings = description?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedLineEndings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return normalizedLineEndings
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

    func setCustomDescription(_ description: String?) {
        let normalizedDescription = Self.normalizedCustomDescription(description)
#if DEBUG
        let inputNewlines = description?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        let normalizedNewlines = normalizedDescription?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        dlog(
            "workspace.customDescription.update workspace=\(id.uuidString.prefix(8)) " +
            "inputLen=\((description as NSString?)?.length ?? 0) " +
            "inputNewlines=\(inputNewlines) " +
            "normalizedLen=\((normalizedDescription as NSString?)?.length ?? 0) " +
            "normalizedNewlines=\(normalizedNewlines) " +
            "input=\"\(debugWorkspaceDescriptionPreview(description))\" " +
            "normalized=\"\(debugWorkspaceDescriptionPreview(normalizedDescription))\""
        )
#endif
        customDescription = normalizedDescription
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

    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) {
        guard panels[panelId] != nil else { return }
        let previousState = panelShellActivityStates[panelId] ?? .unknown
        guard previousState != state else { return }
        panelShellActivityStates[panelId] = state
#if DEBUG
        dlog(
            "surface.shellState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) from=\(previousState.rawValue) to=\(state.rawValue)"
        )
#endif
    }

    func panelNeedsConfirmClose(panelId: UUID, fallbackNeedsConfirmClose: Bool) -> Bool {
        Self.resolveCloseConfirmation(
            shellActivityState: panelShellActivityStates[panelId],
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
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

    func resetSidebarContext(reason: String = "unspecified") {
        statusEntries.removeAll()
        agentPIDs.removeAll()
        agentListeningPorts.removeAll()
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

    func resetBrowserPanelsForContextChange(reason: String) {
        let browserPanels = panels.values.compactMap { $0 as? BrowserPanel }
        guard !browserPanels.isEmpty else { return }

#if DEBUG
        dlog(
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
        remoteDetectedSurfaceIds = remoteDetectedSurfaceIds.filter { validSurfaceIds.contains($0) }
        panelShellActivityStates = panelShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        panelPullRequests = panelPullRequests.filter { validSurfaceIds.contains($0.key) }
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

    func sidebarDirectoriesInDisplayOrder(orderedPanelIds: [UUID]) -> [String] {
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

        if ordered.isEmpty, let fallbackDirectory = normalizedSidebarDirectory(currentDirectory) {
            return [fallbackDirectory]
        }

        return ordered
    }

    func sidebarDirectoriesInDisplayOrder() -> [String] {
        sidebarDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
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
        statusEntries.values.sorted { lhs, rhs in
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

    var isRemoteWorkspace: Bool {
        remoteConfiguration != nil
    }

    @MainActor
    func isRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        activeRemoteTerminalSurfaceIds.contains(panelId)
    }

    @MainActor
    func shouldDemoteWorkspaceAfterChildExit(surfaceId: UUID) -> Bool {
        isRemoteWorkspace || pendingRemoteTerminalChildExitSurfaceIds.contains(surfaceId)
    }

    var remoteDisplayTarget: String? {
        remoteConfiguration?.displayTarget
    }

    var hasActiveRemoteTerminalSessions: Bool {
        activeRemoteTerminalSessionCount > 0
    }

    @MainActor
    func uploadDroppedFilesForRemoteTerminal(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard let controller = remoteSessionController else {
            completion(.failure(RemoteDropUploadError.unavailable))
            return
        }
        controller.uploadDroppedFiles(fileURLs, operation: operation, completion: completion)
    }

    @MainActor
    func uploadDroppedFilesForRemoteTerminal(
        _ fileURLs: [URL],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        uploadDroppedFilesForRemoteTerminal(
            fileURLs,
            operation: TerminalImageTransferOperation(),
            completion: completion
        )
    }

    func syncRemotePortScanTTYs() {
        guard isRemoteWorkspace else { return }
        remoteSessionController?.updateRemotePortScanTTYs(surfaceTTYNames)
    }

    func kickRemotePortScan(panelId: UUID, reason: WorkspaceRemoteSessionController.PortScanKickReason = .command) {
        guard isRemoteWorkspace else { return }
        syncRemotePortScanTTYs()
        remoteSessionController?.kickRemotePortScan(panelId: panelId, reason: reason)
    }

    func remoteStatusPayload() -> [String: Any] {
        let heartbeatAgeSeconds: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return max(0, Date().timeIntervalSince(last))
        }()
        let heartbeatTimestamp: Any = {
            guard let last = remoteLastHeartbeatAt else { return NSNull() }
            return Self.remoteHeartbeatDateFormatter.string(from: last)
        }()
        var payload: [String: Any] = [
            "enabled": remoteConfiguration != nil,
            "state": remoteConnectionState.rawValue,
            "connected": remoteConnectionState == .connected,
            "active_terminal_sessions": activeRemoteTerminalSessionCount,
            "daemon": remoteDaemonStatus.payload(),
            "detected_ports": remoteDetectedPorts,
            "forwarded_ports": remoteForwardedPorts,
            "conflicted_ports": remotePortConflicts,
            "detail": remoteConnectionDetail ?? NSNull(),
            "heartbeat": [
                "count": remoteHeartbeatCount,
                "last_seen_at": heartbeatTimestamp,
                "age_seconds": heartbeatAgeSeconds,
            ],
        ]
        if let endpoint = remoteProxyEndpoint {
            payload["proxy"] = [
                "state": "ready",
                "host": endpoint.host,
                "port": endpoint.port,
                "schemes": ["socks5", "http_connect"],
                "url": "socks5://\(endpoint.host):\(endpoint.port)",
            ]
        } else {
            let proxyState: String
            if hasProxyOnlyRemoteSidebarError {
                proxyState = "error"
            } else {
                switch remoteConnectionState {
                case .connecting:
                    proxyState = "connecting"
                case .error:
                    proxyState = "error"
                default:
                    proxyState = "unavailable"
                }
            }
            payload["proxy"] = [
                "state": proxyState,
                "host": NSNull(),
                "port": NSNull(),
                "schemes": ["socks5", "http_connect"],
                "url": NSNull(),
                "error_code": proxyState == "error" ? "proxy_unavailable" : NSNull(),
            ]
        }
        if let remoteConfiguration {
            payload["destination"] = remoteConfiguration.destination
            payload["port"] = remoteConfiguration.port ?? NSNull()
            payload["has_identity_file"] = remoteConfiguration.identityFile != nil
            payload["has_ssh_options"] = !remoteConfiguration.sshOptions.isEmpty
            payload["local_proxy_port"] = remoteConfiguration.localProxyPort ?? NSNull()
        } else {
            payload["destination"] = NSNull()
            payload["port"] = NSNull()
            payload["has_identity_file"] = false
            payload["has_ssh_options"] = false
            payload["local_proxy_port"] = NSNull()
        }
        return payload
    }

    func configureRemoteConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool = true) {
        skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        remoteConfiguration = configuration
        seedInitialRemoteTerminalSessionIfNeeded(configuration: configuration)
        clearRemoteDetectedSurfacePorts()
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        recomputeListeningPorts()

        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()

        let foregroundAuthToken = Self.normalizedForegroundAuthToken(configuration.foregroundAuthToken)
        let shouldAutoConnect =
            autoConnect
            || (foregroundAuthToken != nil && foregroundAuthToken == pendingRemoteForegroundAuthToken)
        pendingRemoteForegroundAuthToken = nil
        guard shouldAutoConnect else {
            remoteConnectionState = .disconnected
            applyBrowserRemoteWorkspaceStatusToPanels()
            return
        }

        remoteConnectionState = .connecting
        applyBrowserRemoteWorkspaceStatusToPanels()
        let controllerID = UUID()
        let controller = WorkspaceRemoteSessionController(
            workspace: self,
            configuration: configuration,
            controllerID: controllerID
        )
        activeRemoteSessionControllerID = controllerID
        remoteSessionController = controller
        syncRemotePortScanTTYs()
        controller.start()
    }

    func reconnectRemoteConnection() {
        guard let configuration = remoteConfiguration else { return }
        configureRemoteConnection(configuration, autoConnect: true)
    }

    private static func normalizedForegroundAuthToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func notifyRemoteForegroundAuthenticationReady(token: String? = nil) {
        guard let foregroundAuthToken = Self.normalizedForegroundAuthToken(token) else {
            return
        }

        guard let remoteConfiguration else {
            pendingRemoteForegroundAuthToken = foregroundAuthToken
            return
        }

        guard Self.normalizedForegroundAuthToken(remoteConfiguration.foregroundAuthToken) == foregroundAuthToken else {
            return
        }

        pendingRemoteForegroundAuthToken = nil
        guard remoteConnectionState == .disconnected else { return }
        reconnectRemoteConnection()
    }

    func disconnectRemoteConnection(clearConfiguration: Bool = false) {
        let shouldCleanupControlMaster =
            clearConfiguration
            && !isDetachingCloseTransaction
            && pendingDetachedSurfaces.isEmpty
            && !skipControlMasterCleanupAfterDetachedRemoteTransfer
        let configurationForCleanup = shouldCleanupControlMaster ? remoteConfiguration : nil
        let previousController = remoteSessionController
        activeRemoteSessionControllerID = nil
        remoteSessionController = nil
        previousController?.stop()
        pendingRemoteForegroundAuthToken = nil
        activeRemoteTerminalSurfaceIds.removeAll()
        activeRemoteTerminalSessionCount = 0
        pendingRemoteSurfaceTTYName = nil
        pendingRemoteSurfaceTTYSurfaceId = nil
        pendingRemoteSurfacePortKickReason = nil
        pendingRemoteSurfacePortKickSurfaceId = nil
        clearRemoteDetectedSurfacePorts()
        remoteDetectedPorts = []
        remoteForwardedPorts = []
        remotePortConflicts = []
        remoteProxyEndpoint = nil
        remoteHeartbeatCount = 0
        remoteLastHeartbeatAt = nil
        remoteConnectionState = .disconnected
        remoteConnectionDetail = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
        statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
        remoteLastErrorFingerprint = nil
        remoteLastDaemonErrorFingerprint = nil
        remoteLastPortConflictFingerprint = nil
        if clearConfiguration {
            remoteConfiguration = nil
            skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        }
        applyRemoteProxyEndpointUpdate(nil)
        applyBrowserRemoteWorkspaceStatusToPanels()
        recomputeListeningPorts()
        if let configurationForCleanup {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: configurationForCleanup)
        }
    }

    private func clearRemoteConfigurationIfWorkspaceBecameLocal() {
        guard !isDetachingCloseTransaction, panels.isEmpty, remoteConfiguration != nil else { return }
        disconnectRemoteConnection(clearConfiguration: true)
    }

    private func seedInitialRemoteTerminalSessionIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard configuration.terminalStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        guard activeRemoteTerminalSurfaceIds.isEmpty else { return }
        let terminalIds = panels.compactMap { panelId, panel in
            panel is TerminalPanel ? panelId : nil
        }
        guard terminalIds.count == 1, let initialPanelId = terminalIds.first else { return }
        trackRemoteTerminalSurface(initialPanelId)
    }

    private func trackRemoteTerminalSurface(_ panelId: UUID) {
        skipControlMasterCleanupAfterDetachedRemoteTransfer = false
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)
        guard activeRemoteTerminalSurfaceIds.insert(panelId).inserted else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        applyPendingRemoteSurfaceTTYIfNeeded(to: panelId)
        _ = applyPendingRemoteSurfacePortKickIfNeeded(to: panelId)
    }

    private func untrackRemoteTerminalSurface(_ panelId: UUID) {
        guard activeRemoteTerminalSurfaceIds.remove(panelId) != nil else { return }
        activeRemoteTerminalSessionCount = activeRemoteTerminalSurfaceIds.count
        guard !isDetachingCloseTransaction else { return }
        maybeDemoteRemoteWorkspaceAfterSSHSessionEnded()
    }

    private func maybeDemoteRemoteWorkspaceAfterSSHSessionEnded() {
        guard activeRemoteTerminalSurfaceIds.isEmpty, remoteConfiguration != nil else { return }
        let hasBrowserPanels = panels.values.contains { $0 is BrowserPanel }
        if !hasBrowserPanels {
            if remoteConnectionState == .error || remoteDaemonStatus.state == .error || remoteConnectionState == .connecting {
                return
            }
            disconnectRemoteConnection(clearConfiguration: true)
        }
    }

    @MainActor
    func rememberPendingRemoteSurfaceTTY(_ ttyName: String, requestedSurfaceId: UUID?) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }
        pendingRemoteSurfaceTTYName = trimmedTTY
        pendingRemoteSurfaceTTYSurfaceId = requestedSurfaceId
    }

    @MainActor
    func rememberPendingRemoteSurfacePortKick(
        reason: WorkspaceRemoteSessionController.PortScanKickReason,
        requestedSurfaceId: UUID?
    ) {
        pendingRemoteSurfacePortKickReason = reason
        pendingRemoteSurfacePortKickSurfaceId = requestedSurfaceId
    }

    @MainActor
    private func applyPendingRemoteSurfaceTTYIfNeeded(to panelId: UUID) {
        guard let ttyName = pendingRemoteSurfaceTTYName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return
        }
        if let requestedSurfaceId = pendingRemoteSurfaceTTYSurfaceId, requestedSurfaceId != panelId {
            return
        }
        surfaceTTYNames[panelId] = ttyName
        pendingRemoteSurfaceTTYName = nil
        pendingRemoteSurfaceTTYSurfaceId = nil
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: panelId) {
            kickRemotePortScan(panelId: panelId, reason: .command)
        }
    }

    @MainActor
    @discardableResult
    func applyPendingRemoteSurfacePortKickIfNeeded(to panelId: UUID) -> Bool {
        guard let reason = pendingRemoteSurfacePortKickReason else {
            return false
        }
        if let requestedSurfaceId = pendingRemoteSurfacePortKickSurfaceId,
           requestedSurfaceId != panelId {
            return false
        }
        guard let ttyName = surfaceTTYNames[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return false
        }
        _ = ttyName
        pendingRemoteSurfacePortKickReason = nil
        pendingRemoteSurfacePortKickSurfaceId = nil
        kickRemotePortScan(panelId: panelId, reason: reason)
        return true
    }

    @MainActor
    fileprivate func applyBootstrapRemoteTTY(_ ttyName: String) {
        let trimmedTTY = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTTY.isEmpty else { return }

        let candidateSurfaceId: UUID? = {
            if let focusedPanelId, activeRemoteTerminalSurfaceIds.contains(focusedPanelId) {
                return focusedPanelId
            }
            if activeRemoteTerminalSurfaceIds.count == 1 {
                return activeRemoteTerminalSurfaceIds.first
            }
            return nil
        }()

        guard let candidateSurfaceId else {
            rememberPendingRemoteSurfaceTTY(trimmedTTY, requestedSurfaceId: nil)
            return
        }

        surfaceTTYNames[candidateSurfaceId] = trimmedTTY
        syncRemotePortScanTTYs()
        if !applyPendingRemoteSurfacePortKickIfNeeded(to: candidateSurfaceId) {
            kickRemotePortScan(panelId: candidateSurfaceId, reason: .command)
        }
    }

    private func cleanupTransferredRemoteConnectionIfNeeded(surfaceId: UUID, relayPort: Int?) -> Bool {
        guard let relayPort,
              relayPort > 0,
              let cleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId[surfaceId],
              cleanupConfiguration.relayPort == relayPort else {
            return false
        }
        transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: surfaceId)
        Self.requestSSHControlMasterCleanupIfNeeded(configuration: cleanupConfiguration)
        return true
    }

    func markRemoteTerminalSessionEnded(surfaceId: UUID, relayPort: Int?) {
        if cleanupTransferredRemoteConnectionIfNeeded(surfaceId: surfaceId, relayPort: relayPort) {
            return
        }
        guard let relayPort,
              relayPort > 0,
              remoteConfiguration?.relayPort == relayPort else {
            return
        }
        pendingRemoteTerminalChildExitSurfaceIds.insert(surfaceId)
        untrackRemoteTerminalSurface(surfaceId)
    }

    func teardownRemoteConnection() {
        disconnectRemoteConnection(clearConfiguration: true)
    }

    private static func requestSSHControlMasterCleanupIfNeeded(configuration: WorkspaceRemoteConfiguration) {
        guard let arguments = sshControlMasterCleanupArguments(configuration: configuration) else { return }
        if let override = runSSHControlMasterCommandOverrideForTesting {
            override(arguments)
            return
        }

        sshControlMasterCleanupQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSemaphore.signal()
            }

            do {
                try process.run()
                if exitSemaphore.wait(timeout: .now() + 5) == .timedOut {
                    if process.isRunning {
                        process.terminate()
                    }
                    _ = exitSemaphore.wait(timeout: .now() + 1)
                }
            } catch {
                return
            }
        }
    }

    private static func sshControlMasterCleanupArguments(configuration: WorkspaceRemoteConfiguration) -> [String]? {
        let sshOptions = normalizedSSHControlCleanupOptions(configuration.sshOptions)
        var arguments: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]
        if let port = configuration.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = configuration.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identityFile.isEmpty {
            arguments += ["-i", identityFile]
        }
        for option in sshOptions {
            arguments += ["-o", option]
        }
        arguments += ["-O", "exit", configuration.destination]
        return arguments
    }

    private static func normalizedSSHControlCleanupOptions(_ options: [String]) -> [String] {
        let disallowedKeys: Set<String> = ["controlmaster", "controlpersist"]
        return options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let key = sshOptionKeyForControlCleanup(trimmed) else { return nil }
            return disallowedKeys.contains(key) ? nil : trimmed
        }
    }

    private static func sshOptionKeyForControlCleanup(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    func applyRemoteConnectionStateUpdate(
        _ state: WorkspaceRemoteConnectionState,
        detail: String?,
        target: String
    ) {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyOnlyError = trimmedDetail.map(Self.isProxyOnlyRemoteError) ?? false
        let preserveConnectedStateForRetry =
            state == .connecting && preservesSSHTerminalConnection && hasProxyOnlyRemoteSidebarError
        let effectiveState: WorkspaceRemoteConnectionState
        if state == .error && proxyOnlyError && preservesSSHTerminalConnection {
            effectiveState = .connected
        } else if preserveConnectedStateForRetry {
            effectiveState = .connected
        } else {
            effectiveState = state
        }

        remoteConnectionState = effectiveState
        remoteConnectionDetail = detail
        applyBrowserRemoteWorkspaceStatusToPanels()

        if let trimmedDetail, !trimmedDetail.isEmpty, (state == .error || proxyOnlyError) {
            let statusPrefix = proxyOnlyError ? "Remote proxy unavailable" : "SSH error"
            let statusIcon = proxyOnlyError ? "exclamationmark.triangle.fill" : "network.slash"
            let notificationTitle = proxyOnlyError ? "Remote Proxy Unavailable" : "Remote SSH Error"
            let logSource = proxyOnlyError ? "remote-proxy" : "remote"
            statusEntries[Self.remoteErrorStatusKey] = SidebarStatusEntry(
                key: Self.remoteErrorStatusKey,
                value: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                icon: statusIcon,
                color: nil,
                timestamp: Date()
            )

            let fingerprint = "connection:\(trimmedDetail)"
            if remoteLastErrorFingerprint != fingerprint {
                remoteLastErrorFingerprint = fingerprint
                appendSidebarLog(
                    message: "\(statusPrefix) (\(target)): \(trimmedDetail)",
                    level: .error,
                    source: logSource
                )
                AppDelegate.shared?.notificationStore?.addNotification(
                    tabId: id,
                    surfaceId: nil,
                    title: notificationTitle,
                    subtitle: target,
                    body: trimmedDetail,
                    cooldownKey: remoteNotificationCooldownKey(target: target),
                    cooldownInterval: Self.remoteNotificationCooldown
                )
            }
            return
        }

        if state == .connected {
            statusEntries.removeValue(forKey: Self.remoteErrorStatusKey)
            remoteLastErrorFingerprint = nil
        }
    }

    fileprivate func applyRemoteDaemonStatusUpdate(_ status: WorkspaceRemoteDaemonStatus, target: String) {
        remoteDaemonStatus = status
        applyBrowserRemoteWorkspaceStatusToPanels()
        guard status.state == .error else {
            remoteLastDaemonErrorFingerprint = nil
            return
        }
        let trimmedDetail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "remote daemon error"
        let fingerprint = "daemon:\(trimmedDetail)"
        guard remoteLastDaemonErrorFingerprint != fingerprint else { return }
        remoteLastDaemonErrorFingerprint = fingerprint
        appendSidebarLog(
            message: "Remote daemon error (\(target)): \(trimmedDetail)",
            level: .error,
            source: "remote-daemon"
        )
    }

    fileprivate func applyRemoteProxyEndpointUpdate(_ endpoint: BrowserProxyEndpoint?) {
        remoteProxyEndpoint = endpoint
        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            browserPanel.setRemoteProxyEndpoint(endpoint)
        }
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    fileprivate func applyRemoteHeartbeatUpdate(count: Int, lastSeenAt: Date?) {
        remoteHeartbeatCount = max(0, count)
        remoteLastHeartbeatAt = lastSeenAt
        applyBrowserRemoteWorkspaceStatusToPanels()
    }

    fileprivate func applyRemoteDetectedSurfacePortsSnapshot(
        detectedByPanel: [UUID: [Int]],
        detected: [Int],
        forwarded: [Int],
        conflicts: [Int],
        target: String
    ) {
        let trackedSurfaceIds = Set(detectedByPanel.keys)
        for panelId in remoteDetectedSurfaceIds.subtracting(trackedSurfaceIds) {
            surfaceListeningPorts.removeValue(forKey: panelId)
        }
        remoteDetectedSurfaceIds = trackedSurfaceIds

        for (panelId, ports) in detectedByPanel {
            if ports.isEmpty {
                surfaceListeningPorts.removeValue(forKey: panelId)
            } else {
                surfaceListeningPorts[panelId] = ports
            }
        }

        remoteDetectedPorts = detected
        remoteForwardedPorts = forwarded
        remotePortConflicts = conflicts
        recomputeListeningPorts()

        if conflicts.isEmpty {
            statusEntries.removeValue(forKey: Self.remotePortConflictStatusKey)
            remoteLastPortConflictFingerprint = nil
            return
        }

        let conflictsList = conflicts.map { ":\($0)" }.joined(separator: ", ")
        statusEntries[Self.remotePortConflictStatusKey] = SidebarStatusEntry(
            key: Self.remotePortConflictStatusKey,
            value: "SSH port conflicts (\(target)): \(conflictsList)",
            icon: "exclamationmark.triangle.fill",
            color: nil,
            timestamp: Date()
        )

        let fingerprint = conflicts.map(String.init).joined(separator: ",")
        guard remoteLastPortConflictFingerprint != fingerprint else { return }
        remoteLastPortConflictFingerprint = fingerprint
        appendSidebarLog(
            message: "Port conflicts while forwarding \(target): \(conflictsList)",
            level: .warning,
            source: "remote-forward"
        )
    }

    private func clearRemoteDetectedSurfacePorts() {
        for panelId in remoteDetectedSurfaceIds {
            surfaceListeningPorts.removeValue(forKey: panelId)
        }
        remoteDetectedSurfaceIds.removeAll()
    }

    private func appendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
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

    private func seedTerminalInheritanceFontPoints(
        panelId: UUID,
        configTemplate: CmuxSurfaceConfigTemplate?
    ) {
        guard let fontPoints = configTemplate?.fontSize, fontPoints > 0 else { return }
        terminalInheritanceFontPointsByPanelId[panelId] = fontPoints
        lastTerminalConfigInheritanceFontPoints = fontPoints
    }

    private func resolvedTerminalInheritanceFontPoints(
        for terminalPanel: TerminalPanel,
        sourceSurface: ghostty_surface_t,
        inheritedConfig: CmuxSurfaceConfigTemplate
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
        if inheritedConfig.fontSize > 0 {
            return inheritedConfig.fontSize
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
    ) -> CmuxSurfaceConfigTemplate? {
        // Walk candidates in priority order and use the first panel that still exposes
        // a runtime surface pointer.
        for terminalPanel in terminalPanelConfigInheritanceCandidates(
            preferredPanelId: preferredPanelId,
            inPane: preferredPaneId
        ) {
            // Pin the panel and its TerminalSurface wrapper for the duration of
            // this iteration. The raw ghostty_surface_t extracted below is owned
            // by `surface` (the TerminalSurface) — ARC must not release it while
            // ghostty_surface_inherited_config or cmuxCurrentSurfaceFontSizePoints
            // is still reading through the pointer.
            let surface = terminalPanel.surface
            guard let sourceSurface = surface.surface else { continue }
            var config = cmuxInheritedSurfaceConfig(
                sourceSurface: sourceSurface,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
            if let rootedFontPoints = resolvedTerminalInheritanceFontPoints(
                for: terminalPanel,
                sourceSurface: sourceSurface,
                inheritedConfig: config
            ), rootedFontPoints > 0 {
                config.fontSize = rootedFontPoints
                terminalInheritanceFontPointsByPanelId[terminalPanel.id] = rootedFontPoints
            }
            // Prevent ARC from releasing panel/surface before the C calls above complete.
            withExtendedLifetime((terminalPanel, surface)) {}
            rememberTerminalConfigInheritanceSource(terminalPanel)
            if config.fontSize > 0 {
                lastTerminalConfigInheritanceFontPoints = config.fontSize
            }
            return config
        }

        if let fallbackFontPoints = lastTerminalConfigInheritanceFontPoints {
            var config = CmuxSurfaceConfigTemplate()
            config.fontSize = fallbackFontPoints
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
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()

        // Inherit working directory: prefer the source panel's reported cwd,
        // then its requested startup cwd if shell integration has not reported
        // back yet, and finally fall back to the workspace's current directory.
        let splitWorkingDirectory: String? = {
            if let panelDirectory = panelDirectories[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !panelDirectory.isEmpty {
                return panelDirectory
            }
            if let requestedWorkingDirectory = terminalPanel(for: panelId)?
                .requestedWorkingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !requestedWorkingDirectory.isEmpty {
                return requestedWorkingDirectory
            }
            let workspaceDirectory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return workspaceDirectory.isEmpty ? nil : workspaceDirectory
        }()
#if DEBUG
        dlog(
            "split.cwd panelId=\(panelId.uuidString.prefix(5)) panelDir=\(panelDirectories[panelId] ?? "nil") requestedDir=\(terminalPanel(for: panelId)?.requestedWorkingDirectory ?? "nil") currentDir=\(currentDirectory) resolved=\(splitWorkingDirectory ?? "nil")"
        )
#endif

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: splitWorkingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: remoteTerminalStartupCommand
        )
        configureTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        if remoteTerminalStartupCommand != nil {
            trackRemoteTerminalSurface(newPanel.id)
        }
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
            if remoteTerminalStartupCommand != nil {
                untrackRemoteTerminalSurface(newPanel.id)
            }
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

        owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: newPanel.id,
            reason: "splitCreate"
        )

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
        initialInput: String? = nil,
        startupEnvironment: [String: String] = [:]
    ) -> TerminalPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let inheritedConfig = inheritedTerminalConfig(inPane: paneId)
        let remoteTerminalStartupCommand = remoteTerminalStartupCommand()

        // Create new terminal panel
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: remoteTerminalStartupCommand,
            initialInput: initialInput,
            additionalEnvironment: startupEnvironment
        )
        configureTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        if remoteTerminalStartupCommand != nil {
            trackRemoteTerminalSurface(newPanel.id)
        }
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
            if remoteTerminalStartupCommand != nil {
                untrackRemoteTerminalSurface(newPanel.id)
            }
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
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: newPanel.id,
                previousHostedView: previousHostedView
            )
        }

        owningTabManager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: newPanel.id,
            reason: "surfaceCreate"
        )
        return newPanel
    }

    private func remoteTerminalStartupCommand() -> String? {
        guard let command = remoteConfiguration?.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return nil
        }
        return command
    }

    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
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
        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: panelId
            ),
            initialURL: url,
            proxyEndpoint: remoteProxyEndpoint,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil
        )
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
        setPreferredBrowserProfileID(browserPanel.profileID)

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
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

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
        initialRequest: URLRequest? = nil,
        focus: Bool? = nil,
        insertAtEnd: Bool = false,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> BrowserPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let sourcePanelId = effectiveSelectedPanelId(inPane: paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: sourcePanelId
            ),
            initialURL: url,
            initialRequest: initialRequest,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            proxyEndpoint: remoteProxyEndpoint,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil
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
        setPreferredBrowserProfileID(browserPanel.profileID)

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
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserPanel
    }

    /// Open the markdown viewer for `filePath`, reusing an existing
    /// `MarkdownPanel` in this workspace that already shows the same file.
    /// Paths are compared after symlink resolution so `./README.md` and a
    /// symlink pointing at the same file focus the same viewer.
    /// Returns `nil` when no existing viewer matches and split creation
    /// fails, so callers can fall back to the preferred editor / system opener.
    @discardableResult
    func openOrFocusMarkdownSplit(
        from panelId: UUID,
        filePath: String
    ) -> MarkdownPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let md = panel as? MarkdownPanel else { continue }
            if (md.filePath as NSString).resolvingSymlinksInPath == canonical {
                focusPanel(existingId)
                return md
            }
        }
        return newMarkdownSplit(
            from: panelId,
            orientation: .horizontal,
            insertFirst: false,
            filePath: filePath,
            focus: true
        )
    }

    func newMarkdownSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        filePath: String,
        focus: Bool = true
    ) -> MarkdownPanel? {
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

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = markdownPanel.id
        let previousFocusedPanelId = focusedPanelId

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            previousHostedView?.suppressReparentFocus()
            focusPanel(markdownPanel.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                previousHostedView?.clearSuppressReparentFocus()
            }
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func newMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil
    ) -> MarkdownPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = markdownPanel.id
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    /// Tear down all panels in this workspace, freeing their Ghostty surfaces.
    /// Called before the workspace is removed from TabManager to ensure child
    /// processes receive SIGHUP even if ARC deallocation is delayed.
    func teardownAllPanels() {
        // Hide portal-hosted content up front so a workspace being torn down
        // cannot keep drawing above the next selected/restored workspace while
        // panel close work is still unwinding.
        hideAllTerminalPortalViews()
        hideAllBrowserPortalViews()

        let panelEntries = Array(panels)
        for (panelId, panel) in panelEntries {
            panelSubscriptions.removeValue(forKey: panelId)
            PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
            panel.close()
        }

        panels.removeAll(keepingCapacity: false)
        surfaceIdToPanelId.removeAll(keepingCapacity: false)
        panelSubscriptions.removeAll(keepingCapacity: false)
        pendingRemoteTerminalChildExitSurfaceIds.removeAll(keepingCapacity: false)
        pruneSurfaceMetadata(validSurfaceIds: [])
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
        terminalInheritanceFontPointsByPanelId.removeAll(keepingCapacity: false)
        lastTerminalConfigInheritancePanelId = nil
        lastTerminalConfigInheritanceFontPoints = nil
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
        // currently focused (or is the active terminal first responder), close whichever tab
        // bonsplit marks selected in that focused pane.
        let firstResponderPanelId = cmuxOwningGhosttyView(
            for: NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        )?.terminalSurface?.id
        let targetIsActive = focusedPanelId == panelId || firstResponderPanelId == panelId
        guard targetIsActive,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
#if DEBUG
            dlog(
                "surface.close.fallback.skip panel=\(panelId.uuidString.prefix(5)) " +
                "focusedPanel=\(focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                "firstResponderPanel=\(firstResponderPanelId?.uuidString.prefix(5) ?? "nil") " +
                "focusedPane=\(bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil")"
            )
#endif
            return false
        }

        if force {
            forceCloseTabIds.insert(selected.id)
        }
        let closed = bonsplitController.closeTab(selected.id)
#if DEBUG
        dlog(
            "surface.close.fallback panel=\(panelId.uuidString.prefix(5)) " +
            "selectedTab=\(String(describing: selected.id).prefix(5)) " +
            "closed=\(closed ? 1 : 0)"
        )
#endif
        return closed
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

    /// Returns the top-right pane in the current split tree.
    /// When a workspace is already split, sidebar PR opens should reuse an existing pane
    /// instead of creating additional right splits.
    func topRightBrowserReusePane() -> PaneID? {
        let paneIds = bonsplitController.allPaneIds
        guard paneIds.count > 1 else { return nil }

        let paneById = Dictionary(uniqueKeysWithValues: paneIds.map { ($0.id.uuidString, $0) })
        var paneBounds: [String: CGRect] = [:]
        browserCollectNormalizedPaneBounds(
            node: bonsplitController.treeSnapshot(),
            availableRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            into: &paneBounds
        )

        guard !paneBounds.isEmpty else {
            return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
        }

        let epsilon = 0.000_1
        let rightMostX = paneBounds.values.map(\.maxX).max() ?? 0

        let sortedCandidates = paneBounds
            .filter { _, rect in abs(rect.maxX - rightMostX) <= epsilon }
            .sorted { lhs, rhs in
                if abs(lhs.value.minY - rhs.value.minY) > epsilon {
                    return lhs.value.minY < rhs.value.minY
                }
                if abs(lhs.value.minX - rhs.value.minX) > epsilon {
                    return lhs.value.minX > rhs.value.minX
                }
                return lhs.key < rhs.key
            }

        for candidate in sortedCandidates {
            if let pane = paneById[candidate.key] {
                return pane
            }
        }

        return paneIds.sorted { $0.id.uuidString < $1.id.uuidString }.first
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

    private func browserCollectNormalizedPaneBounds(
        node: ExternalTreeNode,
        availableRect: CGRect,
        into output: inout [String: CGRect]
    ) {
        switch node {
        case .pane(let paneNode):
            output[paneNode.id] = availableRect
        case .split(let splitNode):
            let divider = min(max(splitNode.dividerPosition, 0), 1)
            let firstRect: CGRect
            let secondRect: CGRect

            if splitNode.orientation.lowercased() == "vertical" {
                // Stacked split: first = top, second = bottom
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width,
                    height: availableRect.height * divider
                )
                secondRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY + (availableRect.height * divider),
                    width: availableRect.width,
                    height: availableRect.height * (1 - divider)
                )
            } else {
                // Side-by-side split: first = left, second = right
                firstRect = CGRect(
                    x: availableRect.minX,
                    y: availableRect.minY,
                    width: availableRect.width * divider,
                    height: availableRect.height
                )
                secondRect = CGRect(
                    x: availableRect.minX + (availableRect.width * divider),
                    y: availableRect.minY,
                    width: availableRect.width * (1 - divider),
                    height: availableRect.height
                )
            }

            browserCollectNormalizedPaneBounds(node: splitNode.first, availableRect: firstRect, into: &output)
            browserCollectNormalizedPaneBounds(node: splitNode.second, availableRect: secondRect, into: &output)
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
            ?? browserPanel.preferredURLStringForOmnibar().flatMap(URL.init(string:))

        pendingClosedBrowserRestoreSnapshots[tab.id] = ClosedBrowserPanelRestoreSnapshot(
            workspaceId: id,
            url: resolvedURL,
            profileID: browserPanel.profileID,
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
        let shouldSkipControlMasterCleanupAfterDetach =
            activeRemoteTerminalSurfaceIds.contains(panelId)
            && activeRemoteTerminalSurfaceIds.count == 1
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

        var detached = pendingDetachedSurfaces.removeValue(forKey: tabId)
        if shouldSkipControlMasterCleanupAfterDetach, let detachedTransfer = detached, detachedTransfer.isRemoteTerminal {
            skipControlMasterCleanupAfterDetachedRemoteTransfer = true
            if detachedTransfer.remoteCleanupConfiguration == nil {
                detached = detachedTransfer.withRemoteCleanupConfiguration(remoteConfiguration)
            }
        }
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
            browserPanel.reattachToWorkspace(
                id,
                isRemoteWorkspace: isRemoteWorkspace,
                remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil,
                proxyEndpoint: remoteProxyEndpoint,
                remoteStatus: browserRemoteWorkspaceStatusSnapshot()
            )
            installBrowserPanelSubscription(browserPanel)
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let ttyName = detached.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            surfaceTTYNames[detached.panelId] = ttyName
        } else {
            surfaceTTYNames.removeValue(forKey: detached.panelId)
        }
        syncRemotePortScanTTYs()
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
            surfaceTTYNames.removeValue(forKey: detached.panelId)
            syncRemotePortScanTTYs()
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
        let didAdoptWorkspaceRemoteTracking =
            detached.isRemoteTerminal
            && detached.remoteRelayPort == remoteConfiguration?.relayPort
        if didAdoptWorkspaceRemoteTracking {
            trackRemoteTerminalSurface(detached.panelId)
        }
        if let cleanupConfiguration = detached.remoteCleanupConfiguration {
            if didAdoptWorkspaceRemoteTracking {
                transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: detached.panelId)
            } else {
                transferredRemoteCleanupConfigurationsByPanelId[detached.panelId] = cleanupConfiguration
            }
        } else {
            transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: detached.panelId)
        }
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
        let targetPaneShort = targetPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let focusedPaneShort = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabShort = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        let currentPanelShort = currentlyFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.panel.begin workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) trigger=\(String(describing: trigger)) " +
            "targetPane=\(targetPaneShort) focusedPane=\(focusedPaneShort) selectedTab=\(selectedTabShort) " +
            "converged=\(selectionAlreadyConverged ? 1 : 0) " +
            "currentPanel=\(currentPanelShort)"
        )
        if shouldSuppressReentrantRefocus {
            dlog(
                "focus.panel.skipReentrant panel=\(panelId.uuidString.prefix(5)) " +
                "reason=firstResponderAlreadyConverged"
            )
        }
#endif

        if let targetPaneId, !selectionAlreadyConverged {
#if DEBUG
            dlog(
                "focus.panel.focusPane workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(targetPaneId.id.uuidString.prefix(5))"
            )
#endif
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
#if DEBUG
            dlog(
                "focus.panel.selectTab workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5))"
            )
#endif
            bonsplitController.selectTab(tabId)
        }

        if let targetPaneId {
            let activationIntent = panels[panelId]?.preferredFocusIntentForActivation()
            applyTabSelection(
                tabId: tabId,
                inPane: targetPaneId,
                reassertAppKitFocus: !shouldSuppressReentrantRefocus,
                focusIntent: activationIntent,
                previousTerminalHostedView: previousTerminalHostedView
            )
        }

        if let browserPanel = panels[panelId] as? BrowserPanel {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: trigger)
        }

        if trigger == .terminalFirstResponder,
           panels[panelId] is TerminalPanel {
            beginEventDrivenLayoutFollowUp(
                reason: "workspace.focusPanel.terminal",
                terminalFocusPanelId: panelId
            )
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
        let previousFocusedPanelId = focusedPanelId

        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = previousFocusedPanelId, let prev = panels[prevPanelId] {
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

    @discardableResult
    func clearSplitZoom() -> Bool {
        bonsplitController.clearPaneZoom()
    }

    @discardableResult
    func toggleSplitZoom(panelId: UUID) -> Bool {
        let wasSplitZoomed = bonsplitController.isSplitZoomed
        guard let paneId = paneId(forPanelId: panelId) else { return false }
        guard bonsplitController.togglePaneZoom(inPane: paneId) else { return false }
        focusPanel(panelId)
        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: "workspace.toggleSplitZoom")
        if let browserPanel = browserPanel(for: panelId) {
            browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                inPane: paneId,
                reason: "workspace.toggleSplitZoom"
            )
        }
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.toggleSplitZoom",
            browserPanelId: browserPanel(for: panelId) != nil ? panelId : nil,
            browserExitFocusPanelId: (wasSplitZoomed && !bonsplitController.isSplitZoomed) ? panelId : nil,
            includeGeometry: true
        )
        return true
    }

    // MARK: - Context Menu Shortcuts

    static func buildContextMenuShortcuts() -> [TabContextAction: KeyboardShortcut] {
        var shortcuts: [TabContextAction: KeyboardShortcut] = [:]
        let mappings: [(TabContextAction, KeyboardShortcutSettings.Action)] = [
            (.rename, .renameTab),
            (.toggleZoom, .toggleSplitZoom),
            (.newTerminalToRight, .newSurface),
        ]
        for (contextAction, settingsAction) in mappings {
            let stored = KeyboardShortcutSettings.shortcut(for: settingsAction)
            if let key = stored.keyEquivalent {
                shortcuts[contextAction] = KeyboardShortcut(key, modifiers: stored.eventModifiers)
            }
        }
        return shortcuts
    }

    // MARK: - Flash/Notification Support

    func triggerFocusFlash(panelId: UUID) {
        requestAttentionFlash(panelId: panelId, reason: .navigation)
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard terminalPanel(for: panelId) != nil else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        requestAttentionFlash(panelId: panelId, reason: .notificationArrival)
    }

    func triggerNotificationDismissFlash(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }
        requestAttentionFlash(panelId: panelId, reason: .notificationDismiss)
    }

    func triggerDebugFlash(panelId: UUID) {
        guard panels[panelId] != nil else { return }
        focusPanel(panelId)
        requestAttentionFlash(panelId: panelId, reason: .debug)
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

    func hideAllBrowserPortalViews() {
        for panel in panels.values {
            guard let browser = panel as? BrowserPanel else { continue }
            browser.hideBrowserPortalView(source: "workspaceRetire")
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
        configureTerminalPanel(newPanel)
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
        for (panelId, panel) in panels {
            if let terminalPanel = panel as? TerminalPanel,
               panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
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
        pullRequest = panelPullRequests[targetPanelId]
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

    private func beginEventDrivenLayoutFollowUp(
        reason: String,
        browserPanelId: UUID? = nil,
        browserExitFocusPanelId: UUID? = nil,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        layoutFollowUpReason = reason
        if let browserPanelId {
            layoutFollowUpBrowserPanelId = browserPanelId
        }
        if let browserExitFocusPanelId {
            layoutFollowUpBrowserExitFocusPanelId = browserExitFocusPanelId
        }
        if let terminalFocusPanelId {
            layoutFollowUpTerminalFocusPanelId = terminalFocusPanelId
        }
        layoutFollowUpNeedsGeometryPass = layoutFollowUpNeedsGeometryPass || includeGeometry
        layoutFollowUpStalledAttemptCount = 0
        // Invalidate any pending retry whose delay was computed from a stale stall count.
        // Incrementing the version causes old closures to exit early; clearing the flag
        // allows scheduleLayoutFollowUpAttempt() below to enqueue a fresh asyncAfter(0).
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false

        if layoutFollowUpTimeoutWorkItem == nil {
            installLayoutFollowUpObservers()
        }
        refreshLayoutFollowUpTimeout()
        // Use async scheduling instead of a synchronous call here. beginEventDrivenLayoutFollowUp
        // is often invoked from splitTabBar(_:didChangeGeometry:), which fires from inside
        // SwiftUI's .onChange(of: geometry) during an active layout pass. Calling
        // attemptEventDrivenLayoutFollowUp() synchronously in that context causes
        // flushWorkspaceWindowLayouts() → displayIfNeeded() to be called re-entrantly,
        // incrementing AppKit's per-window constraint-pass counter on every display cycle
        // until it exceeds the limit and crashes with NSGenericException.
        // scheduleLayoutFollowUpAttempt() defers via asyncAfter(0) so the flush always
        // happens after the current layout pass completes.
        scheduleLayoutFollowUpAttempt()
    }

    private func installLayoutFollowUpObservers() {
        guard layoutFollowUpTimeoutWorkItem == nil else { return }

        let enqueueAttempt: () -> Void = { [weak self] in
            self?.scheduleLayoutFollowUpAttempt()
        }

        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpPanelsCancellable = $panels
            .map { _ in () }
            .sink { _ in
                enqueueAttempt()
            }
    }

    private func refreshLayoutFollowUpTimeout() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearLayoutFollowUp()
        }
        layoutFollowUpTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func clearLayoutFollowUp() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        layoutFollowUpTimeoutWorkItem = nil
        layoutFollowUpObservers.forEach { NotificationCenter.default.removeObserver($0) }
        layoutFollowUpObservers.removeAll()
        layoutFollowUpPanelsCancellable?.cancel()
        layoutFollowUpPanelsCancellable = nil
        layoutFollowUpReason = nil
        layoutFollowUpTerminalFocusPanelId = nil
        layoutFollowUpBrowserPanelId = nil
        layoutFollowUpBrowserExitFocusPanelId = nil
        layoutFollowUpNeedsGeometryPass = false
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        layoutFollowUpStalledAttemptCount = 0
    }

    private func scheduleLayoutFollowUpAttempt() {
        guard layoutFollowUpTimeoutWorkItem != nil else { return }
        guard !layoutFollowUpAttemptScheduled else { return }

        layoutFollowUpAttemptScheduled = true
        let delay = layoutFollowUpBackoffDelay()
        let version = layoutFollowUpAttemptVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.layoutFollowUpAttemptVersion == version else { return }
            self.layoutFollowUpAttemptScheduled = false
            self.attemptEventDrivenLayoutFollowUp()
        }
    }

    private func layoutFollowUpBackoffDelay() -> TimeInterval {
        guard layoutFollowUpStalledAttemptCount > 0 else { return 0 }
        let baseDelay: TimeInterval = 0.01
        let exponent = min(layoutFollowUpStalledAttemptCount - 1, 5)
        return min(0.25, baseDelay * pow(2.0, Double(exponent)))
    }

    private func flushWorkspaceWindowLayouts() {
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    private func browserPortalAnchorReady(for browserPanel: BrowserPanel) -> Bool {
        let anchorView = browserPanel.portalAnchorView
        return
            anchorView.window != nil &&
            anchorView.superview != nil &&
            anchorView.bounds.width > 1 &&
            anchorView.bounds.height > 1
    }

    private func browserPortalReady(for browserPanel: BrowserPanel) -> Bool {
        browserPortalAnchorReady(for: browserPanel) &&
            browserPanel.webView.window != nil &&
            browserPanel.webView.superview != nil &&
            BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: browserPanel.portalAnchorView)
    }

    private func browserSplitZoomExitFocusNeedsFollowUp(panelId: UUID) -> Bool {
        guard let browserPanel = browserPanel(for: panelId),
              let paneId = paneId(forPanelId: panelId),
              let tabId = surfaceIdFromPanelId(panelId) else {
            return false
        }
        let selectionConverged =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId
        return !selectionConverged || !browserPortalAnchorReady(for: browserPanel)
    }

    private func terminalFocusNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpTerminalFocusPanelId,
              let terminalPanel = terminalPanel(for: panelId) else {
            return false
        }
        return focusedPanelId != panelId || !terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func browserPanelNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpBrowserPanelId,
              let browserPanel = browserPanel(for: panelId) else {
            return false
        }
        return !browserPortalReady(for: browserPanel)
    }

    private func attemptEventDrivenLayoutFollowUp() {
        guard layoutFollowUpTimeoutWorkItem != nil, !isAttemptingLayoutFollowUp else { return }
        isAttemptingLayoutFollowUp = true
        defer { isAttemptingLayoutFollowUp = false }

        flushWorkspaceWindowLayouts()

        let geometryPendingBefore = layoutFollowUpNeedsGeometryPass
        let terminalPortalPendingBefore = terminalPortalVisibilityNeedsFollowUp()
        let browserVisibilityPendingBefore = browserPortalVisibilityNeedsFollowUp()
        let terminalFocusPendingBefore = terminalFocusNeedsFollowUp()
        let browserPanelPendingBefore = browserPanelNeedsFollowUp()
        let browserExitPendingBefore = layoutFollowUpBrowserExitFocusPanelId != nil

        if layoutFollowUpNeedsGeometryPass {
            layoutFollowUpNeedsGeometryPass = reconcileTerminalGeometryPass()
        }

        if let terminalFocusPanelId = layoutFollowUpTerminalFocusPanelId {
            if let terminalPanel = terminalPanel(for: terminalFocusPanelId),
               focusedPanelId == terminalFocusPanelId {
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: terminalFocusPanelId)
                if terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    layoutFollowUpTerminalFocusPanelId = nil
                }
            } else if terminalPanel(for: terminalFocusPanelId) == nil {
                layoutFollowUpTerminalFocusPanelId = nil
            }
        }

        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        let terminalPortalPending = terminalPortalVisibilityNeedsFollowUp()

        let reason = layoutFollowUpReason ?? "workspace.layout"
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: reason)
        let browserVisibilityPending = browserPortalVisibilityNeedsFollowUp()

        if let browserPanelId = layoutFollowUpBrowserPanelId {
            if let browserPanel = browserPanel(for: browserPanelId) {
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let wasReady = browserPortalReady(for: browserPanel)
                if anchorReady && !wasReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(browserPanel.portalAnchorView)
                }
                let isReady = browserPortalReady(for: browserPanel)
                if isReady,
                   (!wasReady || BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.containerHidden == true) {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                }
                if isReady {
                    layoutFollowUpBrowserPanelId = nil
                }
            } else {
                layoutFollowUpBrowserPanelId = nil
            }
        }

        if let browserExitFocusPanelId = layoutFollowUpBrowserExitFocusPanelId {
            if browserSplitZoomExitFocusNeedsFollowUp(panelId: browserExitFocusPanelId) {
                if browserPanel(for: browserExitFocusPanelId) != nil {
                    focusPanel(browserExitFocusPanelId)
                    scheduleFocusReconcile()
                } else {
                    layoutFollowUpBrowserExitFocusPanelId = nil
                }
            } else {
                layoutFollowUpBrowserExitFocusPanelId = nil
            }
        }

        let terminalFocusPending = terminalFocusNeedsFollowUp()
        let browserPanelPending = browserPanelNeedsFollowUp()
        let browserExitPending = layoutFollowUpBrowserExitFocusPanelId != nil
        let needsMoreWork =
            layoutFollowUpNeedsGeometryPass ||
            terminalPortalPending ||
            browserVisibilityPending ||
            terminalFocusPending ||
            browserPanelPending ||
            browserExitPending

        if !needsMoreWork {
            clearLayoutFollowUp()
            return
        }

        let didMakeProgress =
            (geometryPendingBefore && !layoutFollowUpNeedsGeometryPass) ||
            (terminalPortalPendingBefore && !terminalPortalPending) ||
            (browserVisibilityPendingBefore && !browserVisibilityPending) ||
            (terminalFocusPendingBefore && !terminalFocusPending) ||
            (browserPanelPendingBefore && !browserPanelPending) ||
            (browserExitPendingBefore && !browserExitPending)

        if didMakeProgress {
            layoutFollowUpStalledAttemptCount = 0
            scheduleLayoutFollowUpAttempt()
        } else {
            layoutFollowUpStalledAttemptCount += 1
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
            // Re-check surface after reconcileGeometryNow() which can trigger AppKit
            // layout and view lifecycle changes that free surfaces (#432).
            if terminalPanel.surface.surface != nil {
                terminalPanel.surface.forceRefresh()
            }
            if terminalPanel.surface.surface == nil, isAttached && hasUsableBounds {
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                needsFollowUpPass = true
            }
        }

        return needsFollowUpPass
    }

    private func scheduleTerminalGeometryReconcile() {
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.geometry",
            includeGeometry: true
        )
    }

    private func renderedVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        let renderedPaneIds = bonsplitController.zoomedPaneId.map { [$0] } ?? bonsplitController.allPaneIds
        var visiblePanelIds: Set<UUID> = []

        for paneId in renderedPaneIds {
            let selectedTab = bonsplitController.selectedTab(inPane: paneId) ?? bonsplitController.tabs(inPane: paneId).first
            guard let selectedTab,
                  let panelId = panelIdFromSurfaceId(selectedTab.id),
                  panels[panelId] != nil else {
                continue
            }
            visiblePanelIds.insert(panelId)
        }

        if let focusedPanelId,
           panels[focusedPanelId] != nil,
           let focusedPaneId = paneId(forPanelId: focusedPanelId),
           renderedPaneIds.contains(where: { $0.id == focusedPaneId.id }) {
            visiblePanelIds.insert(focusedPanelId)
        }

        return visiblePanelIds
    }

    @discardableResult
    private func reconcileTerminalPortalVisibilityForCurrentRenderedLayout() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            if terminalPanel.hostedView.debugPortalVisibleInUI != shouldBeVisible {
                terminalPanel.hostedView.setVisibleInUI(shouldBeVisible)
                didChange = true
            }
            let shouldBeActive = shouldBeVisible && focusedPanelId == terminalPanel.id
            if terminalPanel.hostedView.debugPortalActive != shouldBeActive {
                terminalPanel.hostedView.setActive(shouldBeActive)
                didChange = true
            }
            TerminalWindowPortalRegistry.updateEntryVisibility(
                for: terminalPanel.hostedView,
                visibleInUI: shouldBeVisible
            )
        }

        return didChange
    }

    private func terminalPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            let hostedView = terminalPanel.hostedView

            if shouldBeVisible {
                if hostedView.isHidden || hostedView.window == nil || hostedView.superview == nil {
                    return true
                }
            } else if !hostedView.isHidden {
                return true
            }
        }

        return false
    }

    @discardableResult
    private func reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: String) -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(browserPanel.id)
            let anchorView = browserPanel.portalAnchorView
            let snapshot = BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)
            if shouldBeVisible {
                if snapshot?.visibleInUI == false {
                    BrowserWindowPortalRegistry.updateEntryVisibility(
                        for: browserPanel.webView,
                        visibleInUI: true,
                        zPriority: 2
                    )
                    didChange = true
                }
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let portalReady = browserPortalReady(for: browserPanel)
                if anchorReady && !portalReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(anchorView)
                    if browserPortalReady(for: browserPanel) {
                        BrowserWindowPortalRegistry.refresh(
                            webView: browserPanel.webView,
                            reason: reason
                        )
                        didChange = true
                    }
                } else if anchorReady && snapshot?.containerHidden == true {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                    didChange = true
                }
            } else {
                let portalNeedsHide =
                    snapshot?.visibleInUI == true ||
                    snapshot?.containerHidden == false
                if portalNeedsHide {
                    if snapshot?.visibleInUI == true {
                        BrowserWindowPortalRegistry.updateEntryVisibility(
                            for: browserPanel.webView,
                            visibleInUI: false,
                            zPriority: 0
                        )
                    }
                    BrowserWindowPortalRegistry.hide(
                        webView: browserPanel.webView,
                        source: reason
                    )
                    didChange = true
                }
            }
        }

        return didChange
    }

    private func browserPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            guard visiblePanelIds.contains(browserPanel.id) else { continue }
            let anchorView = browserPanel.portalAnchorView
            let anchorReady =
                anchorView.window != nil &&
                anchorView.superview != nil &&
                anchorView.bounds.width > 1 &&
                anchorView.bounds.height > 1
            if !anchorReady ||
                browserPanel.webView.window == nil ||
                browserPanel.webView.superview == nil ||
                !BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: anchorView) {
                return true
            }
        }

        return false
    }

    private func scheduleMovedTerminalRefresh(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }

        // Force an NSViewRepresentable update after drag/move reparenting. This keeps
        // portal host binding current when a pane auto-closes during tab moves.
        terminalPanel(for: panelId)?.requestViewReattach()

        let runRefreshPass: (TimeInterval) -> Void = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, let panel = self.terminalPanel(for: panelId) else { return }
                panel.hostedView.reconcileGeometryNow()
                if panel.surface.surface != nil {
                    panel.surface.forceRefresh()
                }
                if panel.surface.surface == nil {
                    panel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
        }

        // Run once immediately and once on the next turn so rapid split close/reparent
        // sequences still get a post-layout redraw.
        runRefreshPass(0)
        runRefreshPass(0.03)
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
        let preferredProfileID = panelIdFromSurfaceId(anchorTabId).flatMap { browserPanel(for: $0)?.profileID }
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true,
            preferredProfileID: preferredProfileID
        ) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func duplicateBrowserToRight(anchorTabId: TabID, inPane paneId: PaneID) {
        guard let panelId = panelIdFromSurfaceId(anchorTabId),
              let browser = browserPanel(for: panelId) else { return }
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: browser.currentURL,
            focus: true,
            preferredProfileID: browser.profileID
        ) else { return }
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
    }

    private func promptRenamePanel(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameTab.title", defaultValue: "Rename Tab")
        alert.informativeText = String(localized: "alert.renameTab.message", defaultValue: "Enter a custom name for this tab.")
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = String(localized: "alert.renameTab.placeholder", defaultValue: "Tab name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameTab.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.cancel", defaultValue: "Cancel"))
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
            (String(localized: "alert.moveTab.newWorkspaceInCurrentWindow", defaultValue: "New Workspace in Current Window"), .newWorkspaceInCurrentWindow),
            (String(localized: "alert.moveTab.selectedWorkspaceInNewWindow", defaultValue: "Selected Workspace in New Window"), .selectedWorkspaceInNewWindow),
        ]
        options.append(contentsOf: workspaceTargets.map { target in
            (target.label, .existingWorkspace(target.workspaceId))
        })

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.moveTab.title", defaultValue: "Move Tab")
        alert.informativeText = String(localized: "alert.moveTab.message", defaultValue: "Choose a destination for this tab.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for option in options {
            popup.addItem(withTitle: option.title)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: String(localized: "alert.moveTab.move", defaultValue: "Move"))
        alert.addButton(withTitle: String(localized: "alert.cancel", defaultValue: "Cancel"))

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
            failure.messageText = String(localized: "alert.moveTab.failed.title", defaultValue: "Move Failed")
            failure.informativeText = String(localized: "alert.moveTab.failed.message", defaultValue: "cmux could not move this tab to the selected destination.")
            failure.addButton(withTitle: String(localized: "alert.ok", defaultValue: "OK"))
            _ = failure.runModal()
        }
    }

    private func handleSessionDrop(
        entry: SessionEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        let inputWithReturn = entry.resumeCommand + "\n"
        switch destination {
        case .insert(let paneId, _):
            let panel = newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: entry.cwd,
                initialInput: inputWithReturn
            )
            return panel != nil
        case .split(let paneId, let orientation, let insertFirst):
            let panel = splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                workingDirectory: entry.cwd,
                initialInput: inputWithReturn
            )
            return panel != nil
        }
    }

    /// Split `paneId` and place a brand-new terminal in the resulting pane.
    /// Used by the session-index drop path; mirrors `newTerminalSplit(from:...)` but
    /// targets a destination pane directly rather than inheriting from a source panel.
    @discardableResult
    func splitPaneWithNewTerminal(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        workingDirectory: String?,
        initialInput: String?
    ) -> TerminalPanel? {
        let inheritedConfig = inheritedTerminalConfig(inPane: paneId)

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialInput: initialInput
        )
        configureTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) != nil else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        newPanel.focus()
        return newPanel
    }

    private func handleExternalTabDrop(_ request: BonsplitController.ExternalTabDropRequest) -> Bool {
        // Session-index drag → spawn a brand new terminal at the destination instead
        // of moving an existing tab.
        if let entry = SessionDragRegistry.shared.consume(id: request.tabId.uuid) {
            return handleSessionDrop(entry: entry, destination: request.destination)
        }

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
    private func shouldCloseWorkspaceOnLastSurface(for tabId: TabID) -> Bool {
        let manager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
        guard panels.count <= 1,
              panelIdFromSurfaceId(tabId) != nil,
              let manager,
              manager.tabs.contains(where: { $0.id == id }) else {
            return false
        }
        return true
    }

    @MainActor
    private func confirmClosePanel(for tabId: TabID) async -> Bool {
        let title = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")
        let panelName: String? = {
            guard let panelId = panelIdFromSurfaceId(tabId) else { return nil }
            if let custom = panelCustomTitles[panelId], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return custom
            }
            if let title = panelTitles[panelId], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
            if let dir = panelDirectories[panelId], !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (dir as NSString).lastPathComponent
            }
            return nil
        }()

        let message: String
        if let panelName {
            message = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(panelName)\".")
        } else {
            message = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        }

        if let confirmCloseHandler = (
            owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        )?.confirmCloseHandler {
            return confirmCloseHandler(title, message, false)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

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
    private func applyTabSelection(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool = true,
        focusIntent: PanelFocusIntent? = nil,
        previousTerminalHostedView: GhosttySurfaceScrollView? = nil
    ) {
        pendingTabSelection = PendingTabSelectionRequest(
            tabId: tabId,
            pane: pane,
            reassertAppKitFocus: reassertAppKitFocus,
            focusIntent: focusIntent,
            previousTerminalHostedView: previousTerminalHostedView
        )
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
            applyTabSelectionNow(
                tabId: request.tabId,
                inPane: request.pane,
                reassertAppKitFocus: request.reassertAppKitFocus,
                focusIntent: request.focusIntent,
                previousTerminalHostedView: request.previousTerminalHostedView
            )
        }
    }

    /// Hide browser portals for tabs that are no longer selected in the given pane.
    private func hideBrowserPortalsForDeselectedTabs(inPane pane: PaneID, selectedTabId: TabID) {
        for tab in bonsplitController.tabs(inPane: pane) {
            guard tab.id != selectedTabId else { continue }
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browserPanel = panels[panelId] as? BrowserPanel else { continue }
            browserPanel.hideBrowserPortalView(source: "tabDeselected")
        }
    }

    private func applyTabSelectionNow(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool,
        focusIntent: PanelFocusIntent?,
        previousTerminalHostedView: GhosttySurfaceScrollView?
    ) {
        let previousFocusedPanelId = focusedPanelId
#if DEBUG
        let focusedPaneBefore = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabBefore = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.split.apply.begin workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5)) " +
            "focusedPane=\(focusedPaneBefore) selectedTab=\(selectedTabBefore) " +
            "reassert=\(reassertAppKitFocus ? 1 : 0)"
        )
#endif
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

        // Focus the selected panel, but keep the previously focused terminal active while a
        // newly created split terminal is still unattached.
        guard let selectedPanelId = panelIdFromSurfaceId(selectedTabId) else {
            return
        }
        let effectiveFocusedPanelId = effectiveSelectedPanelId(inPane: focusedPane) ?? selectedPanelId
        guard let panel = panels[effectiveFocusedPanelId] else {
            return
        }

        if debugStressPreloadSelectionDepth > 0 {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.requestViewReattach()
                scheduleTerminalGeometryReconcile()
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        if shouldTreatCurrentEventAsExplicitFocusIntent() {
            markExplicitFocusIntent(on: effectiveFocusedPanelId)
        }
        let activationIntent = focusIntent ?? panel.preferredFocusIntentForActivation()
        panel.prepareFocusIntentForActivation(activationIntent)
        let panelId = effectiveFocusedPanelId

        syncPinnedStateForTab(selectedTabId, panelId: selectedPanelId)
        syncUnreadBadgeStateForPanel(selectedPanelId)

        // Unfocus all other panels
        for (id, p) in panels where id != effectiveFocusedPanelId {
            p.unfocus()
        }

        // Explicitly hide browser portals for deselected tabs in this pane.
        // Bonsplit's keepAllAlive mode hides non-selected tabs via SwiftUI .opacity(0),
        // but portal-hosted WKWebViews render at the window level in AppKit and are not
        // affected by SwiftUI opacity. Without an explicit hide, the deselected browser's
        // portal layer can remain visible above the newly selected tab.
        hideBrowserPortalsForDeselectedTabs(inPane: focusedPane, selectedTabId: selectedTabId)

        if let focusWindow = activationWindow(for: panel) {
            yieldForeignOwnedFocusIfNeeded(
                in: focusWindow,
                targetPanelId: panelId,
                targetIntent: activationIntent
            )
        }

        activatePanel(
            panel,
            focusIntent: activationIntent,
            reassertAppKitFocus: reassertAppKitFocus
        )
        let focusIntentAllowsBrowserOmnibarAutofocus =
            shouldTreatCurrentEventAsExplicitFocusIntent() ||
            TerminalController.socketCommandAllowsInAppFocusMutations()
        if let browserPanel = panel as? BrowserPanel,
           shouldAllowBrowserOmnibarAutofocus(for: activationIntent),
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
        if reassertAppKitFocus, let terminalPanel = panel as? TerminalPanel {
            if shouldMoveTerminalSurfaceFocus(for: activationIntent),
               !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
#if DEBUG
                let previousExists = previousTerminalHostedView != nil ? 1 : 0
                dlog(
                    "focus.split.moveFocus workspace=\(id.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5)) previousExists=\(previousExists) " +
                    "to=\(panelId.uuidString.prefix(5))"
                )
#endif
                terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
            }
#if DEBUG
            dlog(
                "focus.split.ensureFocus workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(focusedPane.id.uuidString.prefix(5)) " +
                "tab=\(selectedTabId.uuid.uuidString.prefix(5)) intent=\(String(describing: activationIntent))"
            )
#endif
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
        }

        if shouldRestoreFocusIntentAfterActivation(activationIntent) {
            _ = panel.restoreFocusIntent(activationIntent)
        }

        // Update current directory if this is a terminal
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[panelId]
        pullRequest = panelPullRequests[panelId]

        // Post notification
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: self.id,
                GhosttyNotificationKey.surfaceId: panelId
            ]
        )
#if DEBUG
        let prevPanelShort = previousFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.split.apply.end workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) type=\(String(describing: type(of: panel))) " +
            "focusedPane=\(focusedPane.id.uuidString.prefix(5)) selectedTab=\(selectedTabId.uuid.uuidString.prefix(5)) " +
            "prevPanel=\(prevPanelShort)"
        )
#endif
    }

    private func activatePanel(
        _ panel: any Panel,
        focusIntent: PanelFocusIntent,
        reassertAppKitFocus: Bool
    ) {
        if let terminalPanel = panel as? TerminalPanel {
            let shouldFocusTerminalSurface = shouldMoveTerminalSurfaceFocus(for: focusIntent)
            terminalPanel.surface.setFocus(shouldFocusTerminalSurface)
            terminalPanel.hostedView.setActive(true)
            if reassertAppKitFocus && shouldFocusTerminalSurface {
                terminalPanel.focus()
            }
            return
        }

        if let browserPanel = panel as? BrowserPanel {
            guard shouldFocusBrowserWebView(for: focusIntent) else { return }
            browserPanel.focus()
            return
        }

        if reassertAppKitFocus {
            panel.focus()
        }
    }

    private func activationWindow(for panel: any Panel) -> NSWindow? {
        if let terminalPanel = panel as? TerminalPanel {
            return terminalPanel.hostedView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        if let browserPanel = panel as? BrowserPanel {
            return browserPanel.webView.window ?? browserPanel.portalAnchorView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func yieldForeignOwnedFocusIfNeeded(
        in window: NSWindow,
        targetPanelId: UUID,
        targetIntent: PanelFocusIntent
    ) {
        guard let firstResponder = window.firstResponder else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            guard let ownedIntent = panel.ownedFocusIntent(for: firstResponder, in: window) else { continue }
#if DEBUG
            dlog(
                "focus.handoff.begin workspace=\(id.uuidString.prefix(5)) " +
                "fromPanel=\(panelId.uuidString.prefix(5)) toPanel=\(targetPanelId.uuidString.prefix(5)) " +
                "fromIntent=\(String(describing: ownedIntent)) toIntent=\(String(describing: targetIntent))"
            )
#endif
            _ = panel.yieldFocusIntent(ownedIntent, in: window)
            return
        }
    }

    private func shouldMoveTerminalSurfaceFocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .terminal(.findField):
            return false
        default:
            return true
        }
    }

    private func shouldFocusBrowserWebView(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField):
            return false
        default:
            return true
        }
    }

    private func shouldAllowBrowserOmnibarAutofocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.webView), .panel:
            return true
        default:
            return false
        }
    }

    private func shouldRestoreFocusIntentAfterActivation(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField), .terminal(.findField):
            return true
        case .panel, .browser(.webView), .terminal(.surface):
            return false
        }
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

        let explicitUserClose = explicitUserCloseTabIds.remove(tab.id) != nil

        if forceCloseTabIds.contains(tab.id) {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        let closeConfirmationManager = owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager
        if let closeConfirmationManager, closeConfirmationManager.isCloseConfirmationInFlight {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            return false
        }

        if let panelId = panelIdFromSurfaceId(tab.id),
           pinnedPanelIds.contains(panelId) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            NSSound.beep()
            return false
        }

        if explicitUserClose && shouldCloseWorkspaceOnLastSurface(for: tab.id) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            owningTabManager?.closeWorkspaceWithConfirmation(self)
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
        if panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            let confirmationManager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
            if let confirmationManager, !confirmationManager.beginCloseConfirmationSession() {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    confirmationManager?.endCloseConfirmationSession()
                    return
                }
                Task { @MainActor in
                    defer {
                        self.pendingCloseConfirmTabIds.remove(tabId)
                        confirmationManager?.endCloseConfirmationSession()
                    }

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
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)

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
                ttyName: surfaceTTYNames[panelId],
                cachedTitle: cachedTitle,
                customTitle: panelCustomTitles[panelId],
                manuallyUnread: manualUnreadPanelIds.contains(panelId),
                isRemoteTerminal: activeRemoteTerminalSurfaceIds.contains(panelId),
                remoteRelayPort: activeRemoteTerminalSurfaceIds.contains(panelId)
                    ? remoteConfiguration?.relayPort
                    : nil,
                remoteCleanupConfiguration: transferredRemoteCleanupConfiguration
            )
        } else {
            if let closedBrowserRestoreSnapshot {
                onClosedBrowserPanel?(closedBrowserRestoreSnapshot)
            }
            panel?.close()
        }

        panels.removeValue(forKey: panelId)
        untrackRemoteTerminalSurface(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        surfaceIdToPanelId.removeValue(forKey: tabId)
        panelDirectories.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)
        panelShellActivityStates.removeValue(forKey: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        syncRemotePortScanTTYs()
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        terminalInheritanceFontPointsByPanelId.removeValue(forKey: panelId)
        if lastTerminalConfigInheritancePanelId == panelId {
            lastTerminalConfigInheritancePanelId = nil
        }
        clearRemoteConfigurationIfWorkspaceBecameLocal()
        if !isDetaching, let transferredRemoteCleanupConfiguration {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: transferredRemoteCleanupConfiguration)
        }
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)

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
        let movedPanelIdAfter = panelIdFromSurfaceId(tab.id)
#endif
        if let movedPanelId = panelIdFromSurfaceId(tab.id) {
            scheduleMovedTerminalRefresh(panelId: movedPanelId)
        }
#if DEBUG
        let selectedAfter = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneAfter = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        let movedPanelFocused = (movedPanelIdAfter != nil && movedPanelIdAfter == focusedPanelId) ? 1 : 0
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
                untrackRemoteTerminalSurface(panelId)
                pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
                panelDirectories.removeValue(forKey: panelId)
                panelGitBranches.removeValue(forKey: panelId)
                panelPullRequests.removeValue(forKey: panelId)
                panelTitles.removeValue(forKey: panelId)
                panelCustomTitles.removeValue(forKey: panelId)
                pinnedPanelIds.remove(panelId)
                manualUnreadPanelIds.remove(panelId)
                panelSubscriptions.removeValue(forKey: panelId)
                panelShellActivityStates.removeValue(forKey: panelId)
                surfaceTTYNames.removeValue(forKey: panelId)
                surfaceListeningPorts.removeValue(forKey: panelId)
                restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
                PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
            }

            syncRemotePortScanTTYs()
            let closedSet = Set(closedPanelIds)
            surfaceIdToPanelId = surfaceIdToPanelId.filter { !closedSet.contains($0.value) }
            recomputeListeningPorts()
            clearRemoteConfigurationIfWorkspaceBecameLocal()

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
               panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
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
        let rearmBrowserPortalHostReplacement: (PaneID, String) -> Void = { paneId, reason in
            for tab in controller.tabs(inPane: paneId) {
                guard let panelId = self.panelIdFromSurfaceId(tab.id),
                      let browserPanel = self.browserPanel(for: panelId) else {
                    continue
                }
                browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                    inPane: paneId,
                    reason: reason
                )
            }
        }
        rearmBrowserPortalHostReplacement(originalPane, "workspace.didSplit.original")
        rearmBrowserPortalHostReplacement(newPane, "workspace.didSplit.new")

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
                    configureTerminalPanel(replacementPanel)
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

        // Mirror Cmd+D behavior: split buttons should always seed a terminal in the new pane.
        // When the focused source is a browser, inherit terminal config from nearby terminals
        // (or fall back to defaults) instead of leaving an empty selector pane.
        let sourceTabId = controller.selectedTab(inPane: originalPane)?.id
        let sourcePanelId = sourceTabId.flatMap { panelIdFromSurfaceId($0) }

#if DEBUG
        dlog(
            "split.didSplit.autoCreate pane=\(newPane.id.uuidString.prefix(5)) " +
            "fromPane=\(originalPane.id.uuidString.prefix(5)) sourcePanel=\(sourcePanelId.map { String($0.uuidString.prefix(5)) } ?? "none")"
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
        configureTerminalPanel(newPanel)
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
        case .toggleZoom:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            toggleSplitZoom(panelId: panelId)
        @unknown default:
            break
        }
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        tmuxLayoutSnapshot = snapshot
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}

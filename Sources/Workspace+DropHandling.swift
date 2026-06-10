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


// MARK: - Drag and drop handling
extension Workspace {
    private func handleSessionDrop(
        entry: SessionEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard let resumeCommand = entry.resumeCommand else { return false }
        let inputWithReturn = resumeCommand + "\n"
        switch destination {
        case .insert(let paneId, _):
            let panel = newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: entry.resumeWorkingDirectory,
                initialInput: inputWithReturn
            )
            return panel != nil
        case .split(let paneId, let orientation, let insertFirst):
            let panel = splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                workingDirectory: entry.resumeWorkingDirectory,
                initialInput: inputWithReturn
            )
            return panel != nil
        }
    }

    func handleFilePreviewDrop(
        entry: FilePreviewDragEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        switch destination {
        case .insert(let paneId, let index):
            return !openFileSurfaces(
                inPane: paneId,
                filePaths: [entry.filePath],
                focus: true,
                targetIndex: index
            ).isEmpty
        case .split(let paneId, let orientation, let insertFirst):
            return splitPaneWithFileSurface(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: entry.filePath
            ) != nil
        }
    }

    func handleExternalFileDrop(_ request: BonsplitController.ExternalFileDropRequest) -> Bool {
        let entries = request.urls
            .filter(\.isFileURL)
            .map {
                FilePreviewDragEntry(
                    filePath: $0.path,
                    displayTitle: $0.lastPathComponent
                )
            }
        guard !entries.isEmpty else { return false }

        switch request.destination {
        case .insert(let paneId, let index):
            return !openFileSurfaces(
                inPane: paneId,
                filePaths: entries.map(\.filePath),
                focus: true,
                targetIndex: index
            ).isEmpty

        case .split(let sourcePaneId, let orientation, let insertFirst):
            guard let first = entries.first,
                  let firstPanel = splitPaneWithFileSurface(
                    targetPane: sourcePaneId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    filePath: first.filePath
                  ) else {
                return false
            }

            let targetPane = paneId(forPanelId: firstPanel.id) ?? sourcePaneId
            _ = openFileSurfaces(
                inPane: targetPane,
                filePaths: entries.dropFirst().map(\.filePath),
                focus: true
            )
            return true
        }
    }

    @discardableResult
    private func splitPaneWithFileSurface(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> (any Panel)? {
        if MarkdownPanelFileLinkResolver.isMarkdownPathLike(filePath) {
            return splitPaneWithMarkdown(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: filePath
            )
        }
        return splitPaneWithFilePreview(
            targetPane: paneId,
            orientation: orientation,
            insertFirst: insertFirst,
            filePath: filePath
        )
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
        initialInput: String?,
        remoteStartupCommand: String? = nil
    ) -> TerminalPanel? {
        var inheritedConfig = inheritedTerminalConfig(inPane: paneId)
        let requestedRemoteStartupCommand = remoteStartupCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startupCommand = requestedRemoteStartupCommand?.isEmpty == false ? requestedRemoteStartupCommand : nil
        let effectiveStartupEnvironment = terminalStartupEnvironment(
            base: [:],
            remoteStartupCommand: startupCommand
        )
        if startupCommand != nil {
            var template = inheritedConfig ?? CmuxSurfaceConfigTemplate()
            template.waitAfterCommand = true
            inheritedConfig = template
        }

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: startupCommand,
            initialInput: initialInput,
            additionalEnvironment: effectiveStartupEnvironment
        )
        configureNewTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        if startupCommand != nil {
            trackRemoteTerminalSurface(newPanel.id)
        }
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
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            if startupCommand != nil {
                untrackRemoteTerminalSurface(newPanel.id)
            }
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return nil
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: newPanel.id, kind: "terminal", origin: "terminal_split", focused: true)

        bonsplitController.selectTab(newTab.id)
        newPanel.focus()
        return newPanel
    }

    func handleExternalTabDrop(_ request: BonsplitController.ExternalTabDropRequest) -> Bool {
        // Session-index drag → spawn a brand new terminal at the destination instead
        // of moving an existing tab.
        if let entry = SessionDragRegistry.shared.consume(id: request.tabId.uuid) {
            return handleSessionDrop(entry: entry, destination: request.destination)
        }
        if let entry = FilePreviewDragRegistry.shared.consume(id: request.tabId.uuid) {
            return handleFilePreviewDrop(entry: entry, destination: request.destination)
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
        cmuxDebugLog(
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
        cmuxDebugLog(
            "split.externalDrop.end ws=\(id.uuidString.prefix(5)) tab=\(request.tabId.uuid.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(debugElapsedMs(since: dropStart))"
        )
#endif
        return moved
    }

}

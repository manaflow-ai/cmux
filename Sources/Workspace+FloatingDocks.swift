import Bonsplit
import CoreGraphics
import Foundation

extension Workspace {
    /// Creates a workspace-scoped floating window with one native Bonsplit surface.
    @discardableResult
    func createFloatingDock(
        id: UUID = UUID(),
        title: String? = nil,
        frame: CGRect? = nil,
        isPresented: Bool = true,
        initialContent: DockSurfaceKind = .terminal,
        initialURL: URL? = nil,
        backgroundTintHex: String? = nil,
        sessionContent: SessionFloatingDockContentSnapshot? = nil,
        screenFrame: CGRect? = nil,
        displaySnapshot: SessionDisplaySnapshot? = nil,
        configFrames: [SessionConfigFrameEntry]? = nil
    ) -> WorkspaceFloatingDock? {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = resolvedTitle?.isEmpty == false
            ? resolvedTitle!
            : Self.defaultFloatingDockTitle(for: initialContent)
        let noteFileURL = floatingDockNoteFileURL(dockId: id)
        let dock = WorkspaceFloatingDock(
            id: id,
            workspaceId: self.id,
            title: displayTitle,
            frame: Self.sanitizedFloatingDockFrame(frame ?? nextFloatingDockFrame),
            isPresented: isPresented,
            noteFilePath: noteFileURL.path,
            backgroundTintHex: WorkspaceFloatingDockBackgroundColor.normalized(backgroundTintHex),
            initialContent: sessionContent == nil ? initialContent : nil,
            initialURL: initialURL,
            screenFrame: screenFrame,
            displaySnapshot: displaySnapshot,
            configFrames: SessionConfigFrameRing(entries: configFrames ?? []),
            baseDirectoryProvider: { [weak self] in self?.currentDirectory },
            remoteBrowserSettingsProvider: { [weak self] in
                self?.dockRemoteBrowserSettingsSnapshot() ?? .local
            },
            terminalTransferProvider: { [weak self] command, workingDirectory, environment, tmuxStartCommand in
                guard let self,
                      let pane = self.bonsplitController.focusedPaneId
                        ?? self.bonsplitController.allPaneIds.first,
                      let terminal = self.newTerminalSurface(
                        inPane: pane,
                        focus: false,
                        workingDirectory: workingDirectory,
                        initialCommand: command,
                        tmuxStartCommand: tmuxStartCommand,
                        startupEnvironment: environment,
                        preserveFocusWhenUnfocused: true,
                        allowTextBoxFocusDefault: false
                      ) else { return nil }
                return self.detachSurface(panelId: terminal.id)
            }
        )
        if let sessionContent {
            dock.restoreSessionContent(sessionContent)
        }
        floatingDocks.append(dock)
        return dock
    }

    func floatingDock(id: UUID) -> WorkspaceFloatingDock? {
        floatingDocks.first(where: { $0.id == id })
    }

    func floatingDock(selector: String?) -> WorkspaceFloatingDock? {
        guard let selector = selector?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selector.isEmpty else {
            return floatingDocks.first
        }
        if let id = UUID(uuidString: selector) {
            return floatingDock(id: id)
        }
        let normalized = selector.lowercased()
        let numeric = normalized.hasPrefix("float:")
            ? Int(normalized.dropFirst("float:".count))
            : Int(normalized)
        guard let numeric, numeric > 0, floatingDocks.indices.contains(numeric - 1) else { return nil }
        return floatingDocks[numeric - 1]
    }

    @discardableResult
    func closeFloatingDock(id: UUID) -> Bool {
        guard let index = floatingDocks.firstIndex(where: { $0.id == id }) else { return false }
        let dock = floatingDocks.remove(at: index)
        dock.close()
        return true
    }

    @discardableResult
    func closeAllFloatingDocks() -> Int {
        let docks = floatingDocks
        floatingDocks.removeAll(keepingCapacity: true)
        docks.forEach { $0.close() }
        return docks.count
    }

    func floatingDockSessionSnapshots() -> [SessionFloatingDockSnapshot]? {
        let snapshots = floatingDocks.map { dock in
            SessionFloatingDockSnapshot(
                id: dock.id,
                title: dock.title,
                x: dock.frame.origin.x,
                y: dock.frame.origin.y,
                width: dock.frame.width,
                height: dock.frame.height,
                isPresented: dock.isPresented,
                backgroundTintHex: dock.backgroundTintHex,
                content: dock.sessionContentSnapshot(),
                screenFrame: dock.screenFrame.map(SessionRectSnapshot.init),
                display: dock.displaySnapshot,
                configFrames: dock.configFrames.entries.isEmpty ? nil : dock.configFrames.entries
            )
        }
        return snapshots.isEmpty ? nil : snapshots
    }

    func restoreFloatingDocks(from snapshots: [SessionFloatingDockSnapshot]?) {
        floatingDocks.forEach { $0.close() }
        floatingDocks.removeAll()
        for snapshot in snapshots ?? [] {
            _ = createFloatingDock(
                id: snapshot.id,
                title: snapshot.title,
                frame: CGRect(
                    x: snapshot.x,
                    y: snapshot.y,
                    width: snapshot.width,
                    height: snapshot.height
                ),
                isPresented: snapshot.isPresented,
                backgroundTintHex: snapshot.backgroundTintHex,
                sessionContent: snapshot.content,
                screenFrame: snapshot.screenFrame?.cgRect,
                displaySnapshot: snapshot.display,
                configFrames: snapshot.configFrames
            )
        }
    }

    private func floatingDockNoteFileURL(dockId: UUID) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = applicationSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("workspace-notes", isDirectory: true)
            .appendingPathComponent(stableId.uuidString.lowercased(), isDirectory: true)
        return directory.appendingPathComponent("\(dockId.uuidString.lowercased()).md")
    }

    var nextFloatingDockFrame: CGRect {
        let cascade = CGFloat(floatingDocks.count % 6) * 24
        return CGRect(x: 36 + cascade, y: 80 - cascade, width: 520, height: 380)
    }

    private static func defaultFloatingDockTitle(for kind: DockSurfaceKind) -> String {
        switch kind {
        case .note:
            String(localized: "floatingDock.defaultTitle", defaultValue: "Notes")
        case .browser:
            String(localized: "floatingDock.defaultBrowserTitle", defaultValue: "Browser")
        case .terminal:
            String(localized: "floatingDock.defaultTerminalTitle", defaultValue: "Terminal")
        }
    }

    static func sanitizedFloatingDockFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x.isFinite ? frame.origin.x : 36,
            y: frame.origin.y.isFinite ? frame.origin.y : 80,
            width: max(320, frame.width.isFinite ? frame.width : 520),
            height: max(220, frame.height.isFinite ? frame.height : 380)
        )
    }
}

enum WorkspaceFloatingDockBackgroundColor {
    private static let hexadecimalScalars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6,
              digits.unicodeScalars.allSatisfy({ hexadecimalScalars.contains($0) }) else {
            return nil
        }
        return "#\(digits.uppercased())"
    }
}

private enum FloatingDockRestorePlacement {
    case tab(PaneID)
    case split(
        sourcePanelId: UUID,
        orientation: SplitOrientation,
        dividerPosition: CGFloat
    )
}

extension DockSplitStore {
    func floatingDockSessionSnapshot(notePanelId: UUID?) -> SessionFloatingDockContentSnapshot? {
        let rawLayout = BonsplitSessionLayoutCodec.capture(
            controller: bonsplitController,
            panelIdForTab: { [weak self] in self?.surfaceIdToPanelId[$0] }
        )
        let surfaces = BonsplitSessionLayoutCodec.orderedPanelIds(in: rawLayout)
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { floatingDockSurfaceSnapshot(panelId: $0, notePanelId: notePanelId) }
        let persistedPanelIds = Set(surfaces.map(\.id))
        guard !surfaces.isEmpty,
              let layout = BonsplitSessionLayoutCodec.pruning(rawLayout, keeping: persistedPanelIds) else {
            return nil
        }
        return SessionFloatingDockContentSnapshot(
            layout: layout,
            surfaces: surfaces,
            focusedPanelId: focusedPanelId.flatMap { persistedPanelIds.contains($0) ? $0 : nil }
        )
    }

    @discardableResult
    func restoreFloatingDockSessionSnapshot(
        _ snapshot: SessionFloatingDockContentSnapshot,
        noteFilePath: String,
        noteTitle: String
    ) -> UUID? {
        resetForSessionRestore()
        guard let rootPane = bonsplitController.allPaneIds.first else { return nil }
        let surfacesById = Dictionary(uniqueKeysWithValues: snapshot.surfaces.map { ($0.id, $0) })
        var restoredPanelIds: [UUID: UUID] = [:]
        restoreFloatingDockLayout(
            snapshot.layout,
            inPane: rootPane,
            seededPanelId: nil,
            surfacesById: surfacesById,
            restoredPanelIds: &restoredPanelIds,
            noteFilePath: noteFilePath,
            noteTitle: noteTitle
        )
        BonsplitSessionLayoutCodec.applyDividerPositions(snapshot.layout, to: bonsplitController)
        if let oldFocusedPanelId = snapshot.focusedPanelId,
           let focusedPanelId = restoredPanelIds[oldFocusedPanelId],
           let pane = paneId(forPanelId: focusedPanelId),
           let tab = surfaceId(forPanelId: focusedPanelId) {
            restoreDockPaneSelection((pane: pane, tab: tab))
        }
        return snapshot.surfaces.first(where: { $0.kind == .note && $0.filePreview == nil })
            .flatMap { restoredPanelIds[$0.id] }
    }

    private func floatingDockSurfaceSnapshot(
        panelId: UUID,
        notePanelId: UUID?
    ) -> SessionFloatingDockSurfaceSnapshot? {
        guard let panel = panels[panelId] else { return nil }
        if panelId == notePanelId {
            return SessionFloatingDockSurfaceSnapshot(id: panelId, kind: .note)
        }
        if let preview = panel as? FilePreviewPanel {
            return SessionFloatingDockSurfaceSnapshot(
                id: panelId,
                kind: .note,
                filePreview: SessionFilePreviewPanelSnapshot(
                    filePath: preview.filePath,
                    noteTitle: preview.presentation.noteTitle
                )
            )
        }
        if let terminal = panel as? TerminalPanel {
            return SessionFloatingDockSurfaceSnapshot(
                id: panelId,
                kind: .terminal,
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: terminal.requestedWorkingDirectory,
                    tmuxStartCommand: terminal.surface.debugTmuxStartCommand(),
                    textBoxDraft: terminal.sessionTextBoxDraftSnapshot()
                )
            )
        }
        if let browser = panel as? BrowserPanel, browser.shouldPersistSessionSnapshot() {
            return SessionFloatingDockSurfaceSnapshot(
                id: panelId,
                kind: .browser,
                browser: browser.sessionPersistenceSnapshot()
            )
        }
        return nil
    }

    private func restoreFloatingDockLayout(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane pane: PaneID,
        seededPanelId: UUID?,
        surfacesById: [UUID: SessionFloatingDockSurfaceSnapshot],
        restoredPanelIds: inout [UUID: UUID],
        noteFilePath: String,
        noteTitle: String
    ) {
        switch node {
        case .pane(let paneSnapshot):
            for oldPanelId in paneSnapshot.panelIds where oldPanelId != seededPanelId {
                guard let surface = surfacesById[oldPanelId],
                      let newPanelId = restoreFloatingDockSurface(
                        surface,
                        placement: .tab(pane),
                        noteFilePath: noteFilePath,
                        noteTitle: noteTitle
                      ) else { continue }
                restoredPanelIds[oldPanelId] = newPanelId
            }
            if let selectedOldPanelId = paneSnapshot.selectedPanelId,
               let selectedPanelId = restoredPanelIds[selectedOldPanelId],
               let tab = surfaceId(forPanelId: selectedPanelId) {
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(tab)
            }
            if paneSnapshot.isFullWidthTabMode == true {
                _ = bonsplitController.setFullWidthTabMode(true, inPane: pane)
            }
        case .split(let split):
            guard let firstOldPanelId = firstRestorableFloatingDockPanelId(
                in: split.first,
                surfacesById: surfacesById
            ) else { return }
            let firstPanelId: UUID
            if let seededPanelId, let restored = restoredPanelIds[seededPanelId] {
                firstPanelId = restored
            } else {
                guard let surface = surfacesById[firstOldPanelId],
                      let restored = restoreFloatingDockSurface(
                        surface,
                        placement: .tab(pane),
                        noteFilePath: noteFilePath,
                        noteTitle: noteTitle
                      ) else { return }
                restoredPanelIds[firstOldPanelId] = restored
                firstPanelId = restored
            }
            guard let secondOldPanelId = firstRestorableFloatingDockPanelId(
                in: split.second,
                surfacesById: surfacesById
            ),
                  let secondSurface = surfacesById[secondOldPanelId],
                  let secondPanelId = restoreFloatingDockSurface(
                    secondSurface,
                    placement: .split(
                        sourcePanelId: firstPanelId,
                        orientation: split.orientation.splitOrientation,
                        dividerPosition: CGFloat(split.dividerPosition)
                    ),
                    noteFilePath: noteFilePath,
                    noteTitle: noteTitle
                  ),
                  let secondPane = paneId(forPanelId: secondPanelId) else { return }
            restoredPanelIds[secondOldPanelId] = secondPanelId
            restoreFloatingDockLayout(
                split.first,
                inPane: pane,
                seededPanelId: firstOldPanelId,
                surfacesById: surfacesById,
                restoredPanelIds: &restoredPanelIds,
                noteFilePath: noteFilePath,
                noteTitle: noteTitle
            )
            restoreFloatingDockLayout(
                split.second,
                inPane: secondPane,
                seededPanelId: secondOldPanelId,
                surfacesById: surfacesById,
                restoredPanelIds: &restoredPanelIds,
                noteFilePath: noteFilePath,
                noteTitle: noteTitle
            )
        }
    }

    private func firstRestorableFloatingDockPanelId(
        in node: SessionWorkspaceLayoutSnapshot,
        surfacesById: [UUID: SessionFloatingDockSurfaceSnapshot]
    ) -> UUID? {
        BonsplitSessionLayoutCodec.orderedPanelIds(in: node).first { surfacesById[$0] != nil }
    }

    private func restoreFloatingDockSurface(
        _ snapshot: SessionFloatingDockSurfaceSnapshot,
        placement: FloatingDockRestorePlacement,
        noteFilePath: String,
        noteTitle: String
    ) -> UUID? {
        if let filePreview = snapshot.filePreview {
            return restoreFloatingDockFilePreview(filePreview, placement: placement)
        }
        let browserURL = snapshot.browser?.urlString.flatMap { URL(string: $0) }
        let workingDirectory = snapshot.terminal?.workingDirectory
        let panelId: UUID?
        switch placement {
        case .tab(let pane):
            panelId = newSurface(
                kind: snapshot.kind,
                inPane: pane,
                url: browserURL,
                workingDirectory: workingDirectory,
                tmuxStartCommand: snapshot.terminal?.tmuxStartCommand,
                noteFilePath: snapshot.kind == .note ? noteFilePath : nil,
                noteTitle: snapshot.kind == .note ? noteTitle : nil,
                focus: false,
                preferredProfileID: snapshot.browser?.profileID
            )
        case .split(let sourcePanelId, let orientation, let dividerPosition):
            panelId = newSplit(
                kind: snapshot.kind,
                orientation: orientation,
                insertFirst: false,
                sourcePanelId: sourcePanelId,
                url: browserURL,
                workingDirectory: workingDirectory,
                tmuxStartCommand: snapshot.terminal?.tmuxStartCommand,
                noteFilePath: snapshot.kind == .note ? noteFilePath : nil,
                noteTitle: snapshot.kind == .note ? noteTitle : nil,
                preferredProfileID: snapshot.browser?.profileID,
                initialDividerPosition: dividerPosition,
                focus: false
            )
        }
        guard let panelId else { return nil }
        if let browserSnapshot = snapshot.browser,
           let browser = panels[panelId] as? BrowserPanel {
            browser.restoreSessionSnapshot(browserSnapshot)
        }
        if let terminalSnapshot = snapshot.terminal,
           let terminal = panels[panelId] as? TerminalPanel {
            terminal.restoreSessionTextBoxDraft(terminalSnapshot.textBoxDraft)
        }
        return panelId
    }

    private func restoreFloatingDockFilePreview(
        _ snapshot: SessionFilePreviewPanelSnapshot,
        placement: FloatingDockRestorePlacement
    ) -> UUID? {
        let presentation: FilePreviewPresentation = snapshot.noteTitle.map { .note(title: $0) } ?? .file
        let panel = FilePreviewPanel(
            workspaceId: workspaceId,
            filePath: snapshot.filePath,
            presentation: presentation
        )
        switch placement {
        case .tab(let pane):
            guard attachPanelAsTab(
                panel,
                kind: .note,
                title: panel.displayTitle,
                inPane: pane,
                tracksTerminalTitle: false
            ) != nil else { return nil }
        case .split(let sourcePanelId, let orientation, let dividerPosition):
            guard let sourcePane = paneId(forPanelId: sourcePanelId) else { return nil }
            panels[panel.id] = panel
            let tab = Bonsplit.Tab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: "filepreview",
                isDirty: panel.isDirty,
                isPinned: false
            )
            surfaceIdToPanelId[tab.id] = panel.id
            guard withProgrammaticDockSplit({
                bonsplitController.splitPane(
                    sourcePane,
                    orientation: orientation,
                    withTab: tab,
                    insertFirst: false,
                    initialDividerPosition: dividerPosition
                )
            }) != nil else {
                surfaceIdToPanelId.removeValue(forKey: tab.id)
                panels.removeValue(forKey: panel.id)
                panel.close()
                return nil
            }
            installSubscription(for: panel, tracksTerminalTitle: false)
            applyVisibility(to: panel)
        }
        return panel.id
    }
}

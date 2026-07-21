import Bonsplit
import CmuxControlSocket
import Foundation

extension TerminalController: ControlWorkspaceFloatingDockContext {
    private struct FloatingDockNoteWriteTarget: Sendable {
        let workspaceID: UUID
        let dockID: UUID
        let writer: WorkspaceFloatingDockNoteWriter
        let snapshotGeneration: Int
        let writeSequence: UInt64
    }

    private enum FloatingDockNoteWritePreparation: Sendable {
        case resolution(ControlWorkspaceFloatingDockResolution)
        case ready(FloatingDockNoteWriteTarget)
    }

    private struct FloatingDockNoteReadTarget: Sendable {
        let workspaceID: UUID
        let dockID: UUID
        let loader: WorkspaceFloatingDockNoteLoader
        let snapshotGeneration: Int
    }

    private enum FloatingDockNoteReadPreparation: Sendable {
        case resolution(ControlWorkspaceFloatingDockResolution)
        case ready(FloatingDockNoteReadTarget)
    }

    private enum FloatingDockWorkspaceResolution {
        case tabManagerUnavailable
        case notFound
        case found(tabManager: TabManager, workspace: Workspace)
    }

    private func resolveFloatingDockWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> FloatingDockWorkspaceResolution {
        // An explicit window selector scopes every workspace lookup, including
        // the worker-side note-write preparation. Never let the global
        // workspace-owner lookup escape into another window.
        if routing.hasWindowIDParam {
            guard let tabManager = resolveTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            if let workspaceID {
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                    return .notFound
                }
                return .found(tabManager: tabManager, workspace: workspace)
            }
            guard let workspace = tabManager.selectedWorkspace else { return .notFound }
            return .found(tabManager: tabManager, workspace: workspace)
        }
        if let workspaceID {
            if let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
               let workspace = owner.tabs.first(where: { $0.id == workspaceID }) {
                return .found(tabManager: owner, workspace: workspace)
            }
            guard let tabManager = resolveTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
                return .notFound
            }
            return .found(tabManager: tabManager, workspace: workspace)
        }
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let workspace = tabManager.selectedWorkspace else { return .notFound }
        return .found(tabManager: tabManager, workspace: workspace)
    }

    func controlWorkspaceFloatingDock(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        action: ControlWorkspaceFloatingDockAction
    ) -> ControlWorkspaceFloatingDockResolution {
        switch resolveFloatingDockWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable:
            return .tabManagerUnavailable
        case .notFound:
            return .workspaceNotFound
        case .found(let tabManager, let workspace):
            return performFloatingDockAction(action, tabManager: tabManager, workspace: workspace)
        }
    }

    nonisolated func controlSetWorkspaceFloatingDockNote(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        selector: String,
        text: String
    ) -> ControlWorkspaceFloatingDockResolution {
        let preparation: FloatingDockNoteWritePreparation = v2MainSync {
            switch self.resolveFloatingDockWorkspace(routing: routing, workspaceID: workspaceID) {
            case .tabManagerUnavailable:
                return .resolution(.tabManagerUnavailable)
            case .notFound:
                return .resolution(.workspaceNotFound)
            case .found(_, let workspace):
                guard let dock = workspace.floatingDock(selector: selector) else {
                    return .resolution(.floatingDockNotFound)
                }
                let mutation = dock.reserveNoteMutation()
                return .ready(FloatingDockNoteWriteTarget(
                    workspaceID: workspace.id,
                    dockID: dock.id,
                    writer: dock.noteWriter,
                    snapshotGeneration: mutation.snapshotGeneration,
                    writeSequence: mutation.writeSequence
                ))
            }
        }
        guard case .ready(let target) = preparation else {
            if case .resolution(let resolution) = preparation { return resolution }
            return .operationFailed("note mutation failed")
        }

        guard case .saved = target.writer.saveSynchronously(
            content: text,
            sequence: target.writeSequence
        ) else {
            return .operationFailed("note mutation failed")
        }

        return v2MainSync {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: target.workspaceID),
                  let workspace = tabManager.tabs.first(where: { $0.id == target.workspaceID }),
                  let dock = workspace.floatingDocks.first(where: { $0.id == target.dockID }),
                  dock.noteWriter === target.writer else {
                return .operationFailed("note target changed during persistence")
            }
            if dock.noteSnapshotGeneration != target.snapshotGeneration {
                return .resolved(self.floatingDockNotePayload(
                    dock: dock,
                    workspace: workspace,
                    notePanel: self.floatingDockNotePanel(for: dock, tabManager: tabManager),
                    text: dock.noteTextSnapshot
                ))
            }
            let notePanel = self.floatingDockNotePanel(for: dock, tabManager: tabManager)
            guard dock.applyPersistedNoteText(text, to: notePanel) else {
                return .operationFailed("note mutation failed")
            }
            return .resolved(self.floatingDockNotePayload(
                dock: dock,
                workspace: workspace,
                notePanel: notePanel,
                text: text
            ))
        }
    }

    nonisolated func controlGetWorkspaceFloatingDockNote(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        selector: String
    ) -> ControlWorkspaceFloatingDockResolution {
        let preparation: FloatingDockNoteReadPreparation = v2MainSync {
            switch self.resolveFloatingDockWorkspace(routing: routing, workspaceID: workspaceID) {
            case .tabManagerUnavailable:
                return .resolution(.tabManagerUnavailable)
            case .notFound:
                return .resolution(.workspaceNotFound)
            case .found(let tabManager, let workspace):
                guard let dock = workspace.floatingDock(selector: selector) else {
                    return .resolution(.floatingDockNotFound)
                }
                if let text = dock.loadedNoteTextSnapshot {
                    return .resolution(.resolved(self.floatingDockNotePayload(
                        dock: dock,
                        workspace: workspace,
                        notePanel: self.floatingDockNotePanel(for: dock, tabManager: tabManager),
                        text: text
                    )))
                }
                return .ready(FloatingDockNoteReadTarget(
                    workspaceID: workspace.id,
                    dockID: dock.id,
                    loader: dock.noteLoader,
                    snapshotGeneration: dock.reserveNoteSnapshotRead()
                ))
            }
        }
        guard case .ready(let target) = preparation else {
            if case .resolution(let resolution) = preparation { return resolution }
            return .operationFailed("note read failed")
        }

        let loadedText: String
        switch target.loader.loadSynchronously() {
        case .loaded(let text, _):
            loadedText = text
        case .unavailable:
            loadedText = ""
        }

        return v2MainSync {
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: target.workspaceID),
                  let workspace = tabManager.tabs.first(where: { $0.id == target.workspaceID }),
                  let dock = workspace.floatingDocks.first(where: { $0.id == target.dockID }) else {
                return .operationFailed("note target changed during read")
            }
            let text = dock.applyLoadedNoteTextSnapshot(
                loadedText,
                generation: target.snapshotGeneration
            )
            return .resolved(self.floatingDockNotePayload(
                dock: dock,
                workspace: workspace,
                notePanel: self.floatingDockNotePanel(for: dock, tabManager: tabManager),
                text: text
            ))
        }
    }

    private func performFloatingDockAction(
        _ action: ControlWorkspaceFloatingDockAction,
        tabManager: TabManager,
        workspace: Workspace
    ) -> ControlWorkspaceFloatingDockResolution {
        switch action {
        case .list:
            return .resolved(floatingDockListPayload(workspace: workspace, tabManager: tabManager))
        case .create(
            let title,
            let frame,
            let kindRaw,
            let urlRaw,
            let backgroundTintHex,
            let relativeToSelector,
            let focus
        ):
            guard let initialContent = floatingDockInitialContent(kindRaw) else {
                return .invalidInitialContent(kindRaw)
            }
            guard workspace.canCreateFloatingDockPanel else {
                return .operationFailed(Workspace.floatingDockSurfaceLimitErrorMessage)
            }
            let normalizedColor = WorkspaceFloatingDockBackgroundColor.normalized(backgroundTintHex)
            if let backgroundTintHex, normalizedColor == nil {
                return .invalidColor(backgroundTintHex)
            }
            let relativeToDockId: UUID?
            if let relativeToSelector {
                guard let relativeDock = workspace.floatingDock(selector: relativeToSelector) else {
                    return .floatingDockNotFound
                }
                relativeToDockId = relativeDock.id
            } else {
                relativeToDockId = nil
            }
            guard let dock = AppDelegate.shared?.createWorkspaceFloatingDock(
                in: workspace,
                tabManager: tabManager,
                request: WorkspaceFloatingDockCreationRequest(
                    title: title,
                    initialContent: initialContent,
                    initialURL: floatingDockURL(urlRaw, kind: initialContent),
                    frame: frame.map(CGRect.init(controlFrame:)),
                    backgroundTintHex: normalizedColor,
                    focus: focus,
                    relativeToDockId: relativeToDockId
                )
            ) else {
                return .operationFailed("Failed to create floating Dock")
            }
            return .resolved(floatingDockMutationPayload(dock: dock, workspace: workspace, tabManager: tabManager))
        case .setPresented(let selector, let presented, let focus):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            guard AppDelegate.shared?.setWorkspaceFloatingDockPresented(
                dock,
                in: workspace,
                tabManager: tabManager,
                presented: presented,
                focus: focus
            ) == true else {
                return .operationFailed(String(
                    localized: "floatingDock.error.presentation",
                    defaultValue: "Failed to update floating window visibility"
                ))
            }
            return .resolved(floatingDockMutationPayload(dock: dock, workspace: workspace, tabManager: tabManager))
        case .focus(let selector):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            guard AppDelegate.shared?.setWorkspaceFloatingDockPresented(
                dock,
                in: workspace,
                tabManager: tabManager,
                presented: true,
                focus: true
            ) == true else {
                return .operationFailed(String(
                    localized: "floatingDock.error.presentation",
                    defaultValue: "Failed to update floating window visibility"
                ))
            }
            return .resolved(floatingDockMutationPayload(dock: dock, workspace: workspace, tabManager: tabManager))
        case .close(let selector):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            let payload = floatingDockMutationPayload(dock: dock, workspace: workspace, tabManager: tabManager)
            guard AppDelegate.shared?.closeWorkspaceFloatingDock(
                dock,
                in: workspace,
                tabManager: tabManager,
                policy: .force
            ) == true else { return .operationFailed("close cancelled") }
            return .resolved(payload)
        case .closeAll:
            guard let appDelegate = AppDelegate.shared else {
                return .operationFailed("Failed to close floating Docks")
            }
            guard let closedCount = appDelegate.closeAllWorkspaceFloatingDocks(
                in: workspace,
                tabManager: tabManager,
                policy: .force
            ) else { return .operationFailed("close cancelled") }
            return .resolved(.object([
                "workspace_id": .string(workspace.id.uuidString),
                "closed_count": .int(Int64(closedCount)),
            ]))
        case .setFrame(let selector, let frame):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            dock.frame = Workspace.sanitizedFloatingDockFrame(CGRect(controlFrame: frame))
            AppDelegate.shared?.refreshWorkspaceFloatingDocks(for: tabManager)
            return .resolved(floatingDockMutationPayload(dock: dock, workspace: workspace, tabManager: tabManager))
        case .colorGet(let selector):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            return .resolved(floatingDockMutationPayload(dock: dock, workspace: workspace, tabManager: tabManager))
        case .colorSet(let selector, let backgroundTintHex):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            let normalizedColor = WorkspaceFloatingDockBackgroundColor.normalized(backgroundTintHex)
            if let backgroundTintHex, normalizedColor == nil {
                return .invalidColor(backgroundTintHex)
            }
            dock.backgroundTintHex = normalizedColor
            AppDelegate.shared?.refreshWorkspaceFloatingDocks(for: tabManager)
            return .resolved(floatingDockMutationPayload(dock: dock, workspace: workspace, tabManager: tabManager))
        case .noteGet(let selector):
            return .operationFailed(
                "workspace.float.note.get must run on the socket worker (selector: \(selector))"
            )
        case .noteSet(let selector, let text):
            return .operationFailed(
                "workspace.float.note.set must run on the socket worker (selector: \(selector), bytes: \(text.utf8.count))"
            )
        case .surfaceCreate(let selector, let paneID, let kindRaw, let urlRaw, let focus):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            guard let kind = floatingDockSurfaceKind(kindRaw) else { return .invalidSurfaceKind(kindRaw) }
            guard workspace.canCreateFloatingDockPanel else {
                return .operationFailed(Workspace.floatingDockSurfaceLimitErrorMessage)
            }
            guard let pane = dock.store.resolvePane(requestedPaneID: paneID) else { return .paneNotFound }
            guard let panelID = dock.store.newSurface(
                kind: kind,
                inPane: pane,
                url: floatingDockURL(urlRaw, kind: kind),
                focus: focus
            ) else { return .operationFailed("Failed to create floating Dock surface") }
            refreshFloatingDockUI(dock: dock, workspace: workspace, tabManager: tabManager, focus: focus)
            return floatingDockSurfaceMutationPayload(
                dock: dock, workspace: workspace, tabManager: tabManager, panelID: panelID
            )
        case .paneCreate(let selector, let sourceSurfaceID, let kindRaw, let directionRaw, let urlRaw, let focus):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            guard let kind = floatingDockSurfaceKind(kindRaw) else { return .invalidSurfaceKind(kindRaw) }
            guard let direction = floatingDockSplitDirection(directionRaw) else { return .invalidDirection(directionRaw) }
            guard workspace.canCreateFloatingDockPanel else {
                return .operationFailed(Workspace.floatingDockSurfaceLimitErrorMessage)
            }
            if let sourceSurfaceID, !dock.store.containsPanel(sourceSurfaceID) { return .surfaceNotFound }
            guard let panelID = dock.store.newSplit(
                kind: kind,
                orientation: direction.orientation,
                insertFirst: direction.insertFirst,
                sourcePanelId: sourceSurfaceID,
                url: floatingDockURL(urlRaw, kind: kind),
                focus: focus
            ) else { return .operationFailed("Failed to create floating Dock pane") }
            refreshFloatingDockUI(dock: dock, workspace: workspace, tabManager: tabManager, focus: focus)
            return floatingDockSurfaceMutationPayload(
                dock: dock, workspace: workspace, tabManager: tabManager, panelID: panelID
            )
        }
    }

    private func floatingDockSurfaceKind(_ raw: String) -> DockSurfaceKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "terminal": return .terminal
        case "browser": return .browser
        default: return nil
        }
    }

    private func floatingDockInitialContent(_ raw: String) -> DockSurfaceKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "terminal": return .terminal
        case "browser": return .browser
        case "note", "notes": return .note
        default: return nil
        }
    }

    private func floatingDockSplitDirection(
        _ raw: String
    ) -> (orientation: SplitOrientation, insertFirst: Bool)? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left": return (.horizontal, true)
        case "right": return (.horizontal, false)
        case "up", "top": return (.vertical, true)
        case "down", "bottom": return (.vertical, false)
        default: return nil
        }
    }

    private func floatingDockURL(_ raw: String?, kind: DockSurfaceKind) -> URL? {
        guard kind == .browser, let raw else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://\(raw)")
    }

    private func refreshFloatingDockUI(
        dock: WorkspaceFloatingDock,
        workspace: Workspace,
        tabManager: TabManager,
        focus: Bool
    ) {
        if focus, tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        AppDelegate.shared?.refreshWorkspaceFloatingDocks(
            for: tabManager,
            focusDockId: focus ? dock.id : nil
        )
    }

    private func floatingDockListPayload(workspace: Workspace, tabManager: TabManager) -> JSONValue {
        .object([
            "workspace_id": .string(workspace.id.uuidString),
            "selected": .bool(tabManager.selectedTabId == workspace.id),
            "floats": .array(workspace.floatingDocks.enumerated().map { index, dock in
                floatingDockPayload(dock: dock, index: index, workspace: workspace, tabManager: tabManager)
            }),
        ])
    }

    private func floatingDockMutationPayload(
        dock: WorkspaceFloatingDock,
        workspace: Workspace,
        tabManager: TabManager
    ) -> JSONValue {
        let index = workspace.floatingDocks.firstIndex(where: { $0.id == dock.id }) ?? 0
        return floatingDockPayload(dock: dock, index: index, workspace: workspace, tabManager: tabManager)
    }

    private func floatingDockPayload(
        dock: WorkspaceFloatingDock,
        index: Int,
        workspace: Workspace,
        tabManager: TabManager
    ) -> JSONValue {
        let controller = dock.store.bonsplitController
        let focusedPaneID = controller.focusedPaneId?.id
        let panes: [JSONValue] = controller.allPaneIds.map { paneID in
            let selectedTabID = controller.selectedTab(inPane: paneID)?.id
            let surfaces: [JSONValue] = controller.tabs(inPane: paneID).compactMap { tab in
                guard let panel = dock.store.panel(for: tab.id) else { return nil }
                return .object([
                    "id": .string(panel.id.uuidString),
                    "title": .string(panel.displayTitle),
                    "kind": .string(panel === dock.notePanel ? "note" : panel.panelType.rawValue),
                    "selected": .bool(tab.id == selectedTabID),
                ])
            }
            return .object([
                "id": .string(paneID.id.uuidString),
                "focused": .bool(paneID.id == focusedPaneID),
                "surfaces": .array(surfaces),
            ])
        }
        return .object([
            "id": .string(dock.id.uuidString),
            "ref": .string("float:\(index + 1)"),
            "title": .string(dock.title),
            "presented": .bool(dock.isPresented),
            "visible": .bool(dock.isPresented && tabManager.selectedTabId == workspace.id),
            "focused": .bool(dock.ownsInputFocus),
            "background_color": dock.backgroundTintHex.map(JSONValue.string) ?? .null,
            "frame": .object([
                "x": .double(dock.frame.origin.x),
                "y": .double(dock.frame.origin.y),
                "width": .double(dock.frame.width),
                "height": .double(dock.frame.height),
            ]),
            "panes": .array(panes),
        ])
    }

    private func floatingDockNotePayload(
        dock: WorkspaceFloatingDock,
        workspace: Workspace,
        notePanel: FilePreviewPanel?,
        text: String
    ) -> JSONValue {
        .object([
            "workspace_id": .string(workspace.id.uuidString),
            "float_id": .string(dock.id.uuidString),
            "surface_id": notePanel.map { .string($0.id.uuidString) } ?? .null,
            "text": .string(text),
        ])
    }

    private func floatingDockNotePanel(
        for dock: WorkspaceFloatingDock,
        tabManager: TabManager
    ) -> FilePreviewPanel? {
        if let panel = dock.notePanel { return panel }
        for workspace in tabManager.tabs {
            if let panel = workspace.panels.values
                .compactMap({ $0 as? FilePreviewPanel })
                .first(where: { $0.filePath == dock.noteFilePath }) {
                return panel
            }
        }
        for store in DockSplitStore.liveStores {
            if let panel = store.panels.values
                .compactMap({ $0 as? FilePreviewPanel })
                .first(where: { $0.filePath == dock.noteFilePath }) {
                return panel
            }
        }
        return nil
    }

    private func floatingDockSurfaceMutationPayload(
        dock: WorkspaceFloatingDock,
        workspace: Workspace,
        tabManager: TabManager,
        panelID: UUID
    ) -> ControlWorkspaceFloatingDockResolution {
        let index = workspace.floatingDocks.firstIndex(where: { $0.id == dock.id }) ?? 0
        guard let paneID = dock.store.paneId(forPanelId: panelID),
              let panel = dock.store.panels[panelID] else { return .operationFailed("Created surface was not attached") }
        return .resolved(.object([
            "float": floatingDockPayload(
                dock: dock, index: index, workspace: workspace, tabManager: tabManager
            ),
            "pane_id": .string(paneID.id.uuidString),
            "surface_id": .string(panelID.uuidString),
            "kind": .string(panel.panelType.rawValue),
        ]))
    }
}

private extension CGRect {
    init(controlFrame: ControlWorkspaceFloatingDockAction.Frame) {
        self.init(
            x: controlFrame.x,
            y: controlFrame.y,
            width: controlFrame.width,
            height: controlFrame.height
        )
    }
}

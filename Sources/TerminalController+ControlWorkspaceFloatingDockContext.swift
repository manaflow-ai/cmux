import Bonsplit
import CmuxControlSocket
import Foundation

extension TerminalController: ControlWorkspaceFloatingDockContext {
    private enum FloatingDockWorkspaceResolution {
        case tabManagerUnavailable
        case notFound
        case found(tabManager: TabManager, workspace: Workspace)
    }

    private func resolveFloatingDockWorkspace(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> FloatingDockWorkspaceResolution {
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
                tabManager: tabManager
            ) == true else { return .operationFailed("close cancelled") }
            return .resolved(payload)
        case .closeAll:
            guard let appDelegate = AppDelegate.shared else {
                return .operationFailed("Failed to close floating Docks")
            }
            guard let closedCount = appDelegate.closeAllWorkspaceFloatingDocks(
                in: workspace,
                tabManager: tabManager
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
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            let notePanel = floatingDockNotePanel(for: dock, tabManager: tabManager)
            let text = notePanel?.textContent ?? dock.noteTextSnapshot
            return .resolved(floatingDockNotePayload(
                dock: dock, workspace: workspace, notePanel: notePanel, text: text
            ))
        case .noteSet(let selector, let text):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            let notePanel = floatingDockNotePanel(for: dock, tabManager: tabManager)
            do {
                if let notePanel {
                    try notePanel.replaceAutosavedTextContent(text)
                } else {
                    dock.setNoteTextSnapshot(text)
                    let url = URL(fileURLWithPath: dock.noteFilePath)
                    Task {
                        _ = await FilePreviewTextSaver.save(content: text, to: url, encoding: .utf8)
                    }
                }
            } catch {
                cmuxDebugLog("floatingDock.note.set.failed dock=\(dock.id) error=\(error)")
                return .operationFailed("note mutation failed")
            }
            return .resolved(floatingDockNotePayload(
                dock: dock, workspace: workspace, notePanel: notePanel, text: text
            ))
        case .surfaceCreate(let selector, let paneID, let kindRaw, let urlRaw, let focus):
            guard let dock = workspace.floatingDock(selector: selector) else { return .floatingDockNotFound }
            guard let kind = floatingDockSurfaceKind(kindRaw) else { return .invalidSurfaceKind(kindRaw) }
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

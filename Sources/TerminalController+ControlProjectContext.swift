import AppKit
import Bonsplit
import CmuxControlSocket
import CmuxPanes
import Foundation

/// The project-domain witnesses: the byte-faithful bodies of the former
/// `v2ProjectOpen` / `v2ProjectSet*` / `v2ProjectGetState` /
/// `v2MarkdownOpen` / `v2FileOpen` main-actor blocks (the pure path
/// validation moved into the coordinator), minus the per-read `v2MainSync`
/// hops.
extension TerminalController: ControlProjectContext {

    // MARK: - routing probe

    func controlProjectRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    // MARK: - project.open

    func controlProjectOpen(
        routing: ControlRoutingSelectors,
        path: String,
        requestedFocus: Bool
    ) -> ControlProjectOpenResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .workspaceNotFound
        }
        guard let ws = controlProjectResolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)

        guard let paneId = ws.bonsplitController.focusedPaneId else {
            return .noFocusedPane
        }

        guard let panel = ws.newProjectSurface(
            inPane: paneId,
            projectPath: path,
            focus: v2FocusAllowed(requested: requestedFocus)
        ) else {
            return .createFailed
        }
        return .opened(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: ws.paneId(forPanelId: panel.id)?.id,
            surfaceID: panel.id
        )
    }

    // MARK: - project.set_* / get_state

    func controlProjectSetTab(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        tabRaw: String?
    ) -> ControlProjectSetTabResolution {
        guard let (_, panel) = controlProjectResolvePanel(routing: routing, surfaceID: surfaceID) else {
            return .panelNotFound
        }
        guard let raw = tabRaw,
              let tab = ProjectPanelTab(rawValue: raw) else {
            return .invalidTab
        }
        panel.activeTab = tab
        return .set(tab: tab.rawValue)
    }

    func controlProjectSetScheme(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectUpdateResolution {
        guard let (_, panel) = controlProjectResolvePanel(routing: routing, surfaceID: surfaceID) else {
            return .panelNotFound
        }
        panel.selectedSchemeName = name
        return .updated
    }

    func controlProjectSetConfiguration(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectUpdateResolution {
        guard let (_, panel) = controlProjectResolvePanel(routing: routing, surfaceID: surfaceID) else {
            return .panelNotFound
        }
        panel.selectedConfigurationName = name
        return .updated
    }

    func controlProjectSetSelectedTarget(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        name: String?
    ) -> ControlProjectTargetResolution {
        guard let (_, panel) = controlProjectResolvePanel(routing: routing, surfaceID: surfaceID) else {
            return .panelNotFound
        }
        var resolvedID: String?
        if let name, !name.isEmpty,
           let module = panel.loadState.model?.modules.first,
           let target = module.targets.first(where: { $0.displayName == name }) {
            panel.selectedTargetID = target.id
            resolvedID = target.id.rawValue
        } else {
            panel.selectedTargetID = nil
        }
        return .updated(targetID: resolvedID)
    }

    func controlProjectSetSelectedFile(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        path: String?
    ) -> ControlProjectUpdateResolution {
        guard let (_, panel) = controlProjectResolvePanel(routing: routing, surfaceID: surfaceID) else {
            return .panelNotFound
        }
        panel.selectedFilePath = path
        return .updated
    }

    func controlProjectSetSettingsFilter(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        text: String
    ) -> ControlProjectUpdateResolution {
        guard let (_, panel) = controlProjectResolvePanel(routing: routing, surfaceID: surfaceID) else {
            return .panelNotFound
        }
        panel.settingsSearchText = text
        return .updated
    }

    func controlProjectGetState(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> ControlProjectStateResolution {
        guard let (_, panel) = controlProjectResolvePanel(routing: routing, surfaceID: surfaceID) else {
            return .panelNotFound
        }
        let loadState: ControlProjectStateSnapshot.LoadState
        switch panel.loadState {
        case .idle:
            loadState = .idle
        case .loading:
            loadState = .loading
        case let .failed(reason):
            loadState = .failed(reason: reason)
        case let .loaded(model):
            let module = model.modules.first.map { module in
                ControlProjectStateSnapshot.Module(
                    name: module.displayName,
                    targetCount: module.targets.count,
                    targetNames: module.targets.map(\.displayName),
                    schemeCount: module.schemes.count,
                    schemeNames: module.schemes.map(\.name),
                    configurationNames: module.configurationNames,
                    rootGroupChildren: module.rootGroup.children.count
                )
            }
            loadState = .loaded(moduleCount: model.modules.count, module: module)
        }
        return .state(ControlProjectStateSnapshot(
            surfaceID: panel.id,
            projectURLPath: panel.projectURL.path,
            activeTabRawValue: panel.activeTab.rawValue,
            selectedScheme: panel.selectedSchemeName ?? "",
            selectedConfiguration: panel.selectedConfigurationName ?? "",
            selectedTargetID: panel.selectedTargetID?.rawValue ?? "",
            selectedFile: panel.selectedFilePath ?? "",
            settingsFilter: panel.settingsSearchText,
            loadState: loadState
        ))
    }

    // MARK: - markdown.open

    func controlMarkdownOpen(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?,
        filePath: String,
        directionRaw: String,
        fontSize: Double?,
        fontSizeInvalid: Bool,
        requestedFocus: Bool
    ) -> ControlMarkdownOpenResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .workspaceNotFound
        }
        guard let ws = controlProjectResolveWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        v2MaybeFocusWindow(for: tabManager)
        v2MaybeSelectWorkspace(tabManager, workspace: ws)

        let sourceSurfaceId = surfaceID ?? ws.focusedPanelId
        guard let sourceSurfaceId else {
            return .noFocusedSurface
        }
        guard ws.panels[sourceSurfaceId] != nil else {
            return .sourceSurfaceNotFound(sourceSurfaceId)
        }

        let sourcePaneUUID = ws.paneId(forPanelId: sourceSurfaceId)?.id

        guard let direction = SplitDirection(controlToken: directionRaw) else {
            return .invalidDirection
        }
        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
        let insertFirst = (direction == .left || direction == .up)

        if fontSizeInvalid {
            return .invalidFontSize
        }
        let clampedFontSize = fontSize.map { MarkdownFontSizeSettings.clamp($0) }

        let createdPanel = ws.newMarkdownSplit(
            from: sourceSurfaceId,
            orientation: orientation,
            insertFirst: insertFirst,
            filePath: filePath,
            focus: v2FocusAllowed(requested: requestedFocus),
            fontSize: clampedFontSize
        )

        guard let markdownPanelId = createdPanel?.id else {
            return .createFailed
        }

        let targetPaneUUID = ws.paneId(forPanelId: markdownPanelId)?.id
        return .opened(ControlMarkdownOpenResolution.Created(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            targetPaneID: targetPaneUUID,
            surfaceID: markdownPanelId,
            sourceSurfaceID: sourceSurfaceId,
            sourcePaneID: sourcePaneUUID
        ))
    }

    // MARK: - file.open

    /// `file.open` forwards to the single shared `v2FileOpen` body (also driven
    /// directly by cmuxTests), bridging its Foundation result — one source of
    /// truth, byte-identical wire output.
    func controlFileOpen(params: [String: JSONValue]) -> ControlCallResult {
        switch v2FileOpen(params: params.mapValues(\.foundationObject)) {
        case let .ok(payload):
            return .ok(JSONValue(foundationObject: payload) ?? .object([:]))
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }

    // MARK: - Resolution helpers (private, file-scoped)

    /// The routing-driven twin of the legacy `v2ResolveWorkspace(params:tabManager:)`.
    private func controlProjectResolveWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            return tabManager.tabs.first(where: { $0.panels[surfaceId] != nil })
        }
        if let paneId = routing.paneID, let located = v2LocatePane(paneId) {
            guard located.tabManager === tabManager else { return nil }
            return located.workspace
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// The routing-driven twin of the legacy `v2ResolveProjectPanel`.
    private func controlProjectResolvePanel(
        routing: ControlRoutingSelectors,
        surfaceID: UUID?
    ) -> (Workspace, ProjectPanel)? {
        guard let tabManager = resolveTabManager(routing: routing) else { return nil }
        guard let ws = controlProjectResolveWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let surfaceId = surfaceID ?? ws.focusedPanelId
        guard let surfaceId,
              let panel = ws.panels[surfaceId] as? ProjectPanel else { return nil }
        return (ws, panel)
    }
}

import Bonsplit
import Foundation

/// Snapshot of a live workspace as a reusable `type: "workspace"` config
/// action ("Save Workspace as Action" in the new-workspace menu).
struct WorkspaceConfigActionSnapshot {
    var definition: CmuxWorkspaceDefinition
    /// Panels with no representation in the layout schema (file previews,
    /// markdown viewers, custom sidebars, …) that were left out.
    var skippedPanelCount: Int
}

extension Workspace {
    /// Captures the live split tree, per-panel directories, browser URLs, and
    /// detected agent CLIs into a `CmuxWorkspaceDefinition` that
    /// `applyCustomLayout` can recreate.
    func captureConfigActionSnapshot() -> WorkspaceConfigActionSnapshot {
        var skippedPanelCount = 0
        let workspaceCwd = Self.configCaptureAbbreviatedPath(currentDirectory)
        let liveCommands = TerminalForegroundCommandCapture.liveCommandsBySurfaceUUID()
        let layout = configCaptureLayoutNode(
            from: bonsplitController.treeSnapshot(),
            workspaceCwd: workspaceCwd,
            liveCommands: liveCommands,
            skippedPanelCount: &skippedPanelCount
        )

        var definition = CmuxWorkspaceDefinition()
        definition.name = customTitle
        definition.cwd = workspaceCwd.isEmpty ? nil : workspaceCwd
        definition.color = customColor
        definition.env = workspaceEnvironment.isEmpty ? nil : workspaceEnvironment
        definition.layout = Self.configCaptureSimplifiedLayout(layout)
        return WorkspaceConfigActionSnapshot(
            definition: definition,
            skippedPanelCount: skippedPanelCount
        )
    }

    private func configCaptureLayoutNode(
        from node: ExternalTreeNode,
        workspaceCwd: String,
        liveCommands: [UUID: String],
        skippedPanelCount: inout Int
    ) -> CmuxLayoutNode? {
        switch node {
        case .split(let split):
            let first = configCaptureLayoutNode(
                from: split.first,
                workspaceCwd: workspaceCwd,
                liveCommands: liveCommands,
                skippedPanelCount: &skippedPanelCount
            )
            let second = configCaptureLayoutNode(
                from: split.second,
                workspaceCwd: workspaceCwd,
                liveCommands: liveCommands,
                skippedPanelCount: &skippedPanelCount
            )
            switch (first, second) {
            case (let first?, let second?):
                return .split(CmuxSplitDefinition(
                    direction: split.orientation == "vertical" ? .vertical : .horizontal,
                    split: (split.dividerPosition * 100).rounded() / 100,
                    children: [first, second]
                ))
            case (let first?, nil):
                return first
            case (nil, let second?):
                return second
            case (nil, nil):
                return nil
            }
        case .pane(let pane):
            guard let paneId = bonsplitController.allPaneIds.first(where: { $0.id.uuidString == pane.id }) else {
                return nil
            }
            let surfaces = bonsplitController.tabs(inPane: paneId).compactMap { tab -> CmuxSurfaceDefinition? in
                guard let panelId = panelIdFromSurfaceId(tab.id) else { return nil }
                return configCaptureSurfaceDefinition(
                    panelId: panelId,
                    tabUUID: tab.id.uuid,
                    workspaceCwd: workspaceCwd,
                    liveCommands: liveCommands,
                    skippedPanelCount: &skippedPanelCount
                )
            }
            guard !surfaces.isEmpty else { return nil }
            return .pane(CmuxPaneDefinition(surfaces: surfaces))
        }
    }

    private func configCaptureSurfaceDefinition(
        panelId: UUID,
        tabUUID: UUID,
        workspaceCwd: String,
        liveCommands: [UUID: String],
        skippedPanelCount: inout Int
    ) -> CmuxSurfaceDefinition? {
        let customName = panelCustomTitles[panelId]
        let focus: Bool? = (panelId == focusedPanelId) ? true : nil
        switch panels[panelId] {
        case is TerminalPanel:
            var surface = CmuxSurfaceDefinition(type: .terminal)
            surface.name = customName
            surface.cwd = configCaptureSurfaceCwd(panelDirectories[panelId], workspaceCwd: workspaceCwd)
            if let liveCommand = liveCommands[panelId] ?? liveCommands[tabUUID] {
                // What the terminal is actually running right now (foreground
                // argv, agent resume flags stripped so relaunch is fresh).
                surface.command = liveCommand
            } else if let agent = SharedLiveAgentIndex.shared.snapshot(workspaceId: id, panelId: panelId) {
                // Fallback: hook-tracked agent with no readable foreground argv.
                surface.command = agent.kind.rawValue
            }
            surface.focus = focus
            return surface
        case let browser as BrowserPanel:
            var surface = CmuxSurfaceDefinition(type: .browser)
            surface.name = customName
            surface.url = browser.currentURL?.absoluteString
            surface.focus = focus
            return surface
        case let project as ProjectPanel:
            var surface = CmuxSurfaceDefinition(type: .project)
            surface.name = customName
            surface.url = Self.configCaptureAbbreviatedPath(project.projectURL.path)
            surface.focus = focus
            return surface
        case let agentSession as AgentSessionPanel:
            var surface = CmuxSurfaceDefinition(type: .terminal)
            surface.name = customName
            surface.command = agentSession.currentProviderID.executableName
            surface.cwd = configCaptureSurfaceCwd(agentSession.workingDirectory, workspaceCwd: workspaceCwd)
            surface.focus = focus
            return surface
        default:
            skippedPanelCount += 1
            return nil
        }
    }

    private func configCaptureSurfaceCwd(_ rawPath: String?, workspaceCwd: String) -> String? {
        guard let rawPath, !rawPath.isEmpty else { return nil }
        let abbreviated = Self.configCaptureAbbreviatedPath(rawPath)
        return abbreviated == workspaceCwd ? nil : abbreviated
    }

    private static func configCaptureAbbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// A single plain terminal (no command, name, or divergent cwd) carries no
    /// information beyond the workspace itself — drop the layout entirely.
    private static func configCaptureSimplifiedLayout(_ layout: CmuxLayoutNode?) -> CmuxLayoutNode? {
        guard case .pane(let pane)? = layout, pane.surfaces.count == 1 else { return layout }
        let surface = pane.surfaces[0]
        let isPlainTerminal = surface.type == .terminal
            && surface.command == nil
            && surface.name == nil
            && surface.cwd == nil
            && surface.url == nil
        return isPlainTerminal ? nil : layout
    }
}

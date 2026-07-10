import Bonsplit
import Foundation

/// Snapshot of a live workspace as a reusable `type: "workspace"` config
/// action (saved as a workspace layout from the new-workspace menu).
nonisolated struct WorkspaceConfigActionSnapshot: Sendable {
    var definition: CmuxWorkspaceDefinition
    /// Panels with no representation in the layout schema (file previews,
    /// markdown viewers, custom sidebars, …) that were left out.
    var skippedPanelCount: Int

    /// Every shell command the saved action would persist and re-run. The save
    /// dialog shows these verbatim so secret-bearing foreground commands are
    /// never written without the user seeing them first.
    var capturedCommands: [String] {
        collectSurfaceValues { $0.command }
    }

    /// Every URL the saved action would persist (browser tabs, project panels).
    /// Disclosed in the save dialog — URLs can carry OAuth codes, presigned
    /// tokens, or private query parameters.
    var capturedURLs: [String] {
        collectSurfaceValues { $0.url }
    }

    /// Names of environment variables the saved action would persist
    /// (workspace-level and per-surface). Values are written to the config, so
    /// the dialog discloses which keys are involved before saving.
    var capturedEnvironmentKeys: [String] {
        var keys = Set<String>()
        if let workspaceEnv = definition.env {
            keys.formUnion(workspaceEnv.keys)
        }
        if let layout = definition.layout {
            Self.walkSurfaces(layout) { surface in
                if let surfaceEnv = surface.env {
                    keys.formUnion(surfaceEnv.keys)
                }
            }
        }
        return keys.sorted()
    }

    /// Commands too long to replay through a freshly spawned shell's canonical tty line buffer.
    var oversizedCommands: [String] {
        var commands: [String] = []
        if let setup = definition.setup {
            commands.append(setup)
        }
        commands.append(contentsOf: capturedCommands)
        return commands.filter {
            $0.utf8.count > TerminalForegroundCommandCapture.maxReplayableCommandUTF8Length
        }
    }

    private func collectSurfaceValues(_ value: (CmuxSurfaceDefinition) -> String?) -> [String] {
        guard let layout = definition.layout else { return [] }
        var values: [String] = []
        Self.walkSurfaces(layout) { surface in
            if let extracted = value(surface) {
                values.append(extracted)
            }
        }
        return values
    }

    private static func walkSurfaces(_ node: CmuxLayoutNode, visit: (CmuxSurfaceDefinition) -> Void) {
        switch node {
        case .pane(let pane):
            for surface in pane.surfaces {
                visit(surface)
            }
        case .split(let split):
            for child in split.children {
                walkSurfaces(child, visit: visit)
            }
        }
    }
}

extension Workspace {
    /// Captures every layout/UI value synchronously on the main actor. The
    /// returned value can safely cross an await while foreground commands are
    /// discovered without rereading live workspace state afterward.
    func captureConfigActionState() -> WorkspaceConfigActionCapture {
        var ttyDeviceByPanelID: [UUID: Int64] = [:]
        for (panelID, ttyName) in surfaceTTYNames {
            if let device = CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: ttyName) {
                ttyDeviceByPanelID[panelID] = device
            }
        }
        var skippedPanelCount = 0
        var nextSurfaceOrdinal = 0
        var terminalCommandTargets: [WorkspaceConfigActionCapture.TerminalCommandTarget] = []
        let workspaceCwd = Self.configCaptureAbbreviatedPath(currentDirectory)
        let layout = configCaptureLayoutNode(
            from: bonsplitController.treeSnapshot(),
            workspaceCwd: workspaceCwd,
            ttyDeviceByPanelID: ttyDeviceByPanelID,
            nextSurfaceOrdinal: &nextSurfaceOrdinal,
            terminalCommandTargets: &terminalCommandTargets,
            skippedPanelCount: &skippedPanelCount
        )

        var definition = CmuxWorkspaceDefinition()
        definition.name = customTitle
        definition.cwd = workspaceCwd.isEmpty ? nil : workspaceCwd
        definition.color = customColor
        // Deliberately no env: workspaceEnvironment values can be secrets and
        // the dialog can only disclose keys. Users add env by hand via
        // Customize Workspace Layouts when they want it persisted.
        // Simplification happens after command enrichment so a plain terminal
        // with a live foreground command cannot be discarded prematurely.
        definition.layout = layout
        return WorkspaceConfigActionCapture(
            snapshot: WorkspaceConfigActionSnapshot(
                definition: definition,
                skippedPanelCount: skippedPanelCount
            ),
            initialName: customTitle
                ?? URL(fileURLWithPath: currentDirectory).lastPathComponent,
            terminalCommandTargets: terminalCommandTargets
        )
    }

    private func configCaptureLayoutNode(
        from node: ExternalTreeNode,
        workspaceCwd: String,
        ttyDeviceByPanelID: [UUID: Int64],
        nextSurfaceOrdinal: inout Int,
        terminalCommandTargets: inout [WorkspaceConfigActionCapture.TerminalCommandTarget],
        skippedPanelCount: inout Int
    ) -> CmuxLayoutNode? {
        switch node {
        case .split(let split):
            let first = configCaptureLayoutNode(
                from: split.first,
                workspaceCwd: workspaceCwd,
                ttyDeviceByPanelID: ttyDeviceByPanelID,
                nextSurfaceOrdinal: &nextSurfaceOrdinal,
                terminalCommandTargets: &terminalCommandTargets,
                skippedPanelCount: &skippedPanelCount
            )
            let second = configCaptureLayoutNode(
                from: split.second,
                workspaceCwd: workspaceCwd,
                ttyDeviceByPanelID: ttyDeviceByPanelID,
                nextSurfaceOrdinal: &nextSurfaceOrdinal,
                terminalCommandTargets: &terminalCommandTargets,
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
            var surfaces: [CmuxSurfaceDefinition] = []
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id),
                      let surface = configCaptureSurfaceDefinition(
                    panelId: panelId,
                    workspaceCwd: workspaceCwd,
                    surfaceOrdinal: nextSurfaceOrdinal,
                    ttyDeviceByPanelID: ttyDeviceByPanelID,
                    terminalCommandTargets: &terminalCommandTargets,
                    skippedPanelCount: &skippedPanelCount
                ) else { continue }
                surfaces.append(surface)
                nextSurfaceOrdinal += 1
            }
            guard !surfaces.isEmpty else { return nil }
            return .pane(CmuxPaneDefinition(surfaces: surfaces))
        }
    }

    private func configCaptureSurfaceDefinition(
        panelId: UUID,
        workspaceCwd: String,
        surfaceOrdinal: Int,
        ttyDeviceByPanelID: [UUID: Int64],
        terminalCommandTargets: inout [WorkspaceConfigActionCapture.TerminalCommandTarget],
        skippedPanelCount: inout Int
    ) -> CmuxSurfaceDefinition? {
        let customName = panelCustomTitles[panelId]
        let focus: Bool? = (panelId == focusedPanelId) ? true : nil
        switch panels[panelId] {
        case is TerminalPanel:
            var surface = CmuxSurfaceDefinition(type: .terminal)
            surface.name = customName
            surface.cwd = configCaptureSurfaceCwd(panelDirectories[panelId], workspaceCwd: workspaceCwd)
            // Panel identity comes from the workspace-owned tty registry,
            // never from a child process's spoofable CMUX_* environment.
            if let ttyDevice = ttyDeviceByPanelID[panelId] {
                terminalCommandTargets.append(.init(
                    surfaceOrdinal: surfaceOrdinal,
                    ttyDevice: ttyDevice
                ))
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

}

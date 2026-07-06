import Bonsplit
import Foundation

enum SavedLayoutCaptureError: Error, Equatable, LocalizedError {
    case unsupportedSplitOrientation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSplitOrientation(let orientation):
            return "Unsupported split orientation in layout capture: \(orientation)"
        }
    }
}

struct CmuxWorkspaceLayoutCapture {
    var workspace: CmuxWorkspaceDefinition
    var unsupportedSurfaceCount: Int
}

extension Workspace {
    func captureLayoutDefinition() throws -> CmuxWorkspaceLayoutCapture {
        var unsupportedSurfaceCount = 0
        let baseCwd = currentDirectory
        let root = try captureLayoutNode(
            from: bonsplitController.treeSnapshot(),
            baseCwd: baseCwd,
            unsupportedSurfaceCount: &unsupportedSurfaceCount
        )
        let workspaceDefinition = CmuxWorkspaceDefinition(
            name: nil,
            cwd: baseCwd,
            color: customColor,
            env: workspaceEnvironment.isEmpty ? nil : workspaceEnvironment,
            layout: root
        )
        return CmuxWorkspaceLayoutCapture(
            workspace: workspaceDefinition,
            unsupportedSurfaceCount: unsupportedSurfaceCount
        )
    }

    private func captureLayoutNode(
        from node: ExternalTreeNode,
        baseCwd: String,
        unsupportedSurfaceCount: inout Int
    ) throws -> CmuxLayoutNode {
        switch node {
        case .split(let split):
            let direction: CmuxSplitDirection
            switch split.orientation.lowercased() {
            case "horizontal":
                direction = .horizontal
            case "vertical":
                direction = .vertical
            default:
                throw SavedLayoutCaptureError.unsupportedSplitOrientation(split.orientation)
            }
            return .split(
                CmuxSplitDefinition(
                    direction: direction,
                    split: Self.clampedSavedLayoutSplit(split.dividerPosition),
                    children: [
                        try captureLayoutNode(from: split.first, baseCwd: baseCwd, unsupportedSurfaceCount: &unsupportedSurfaceCount),
                        try captureLayoutNode(from: split.second, baseCwd: baseCwd, unsupportedSurfaceCount: &unsupportedSurfaceCount),
                    ]
                )
            )
        case .pane(let pane):
            let surfaces = captureSurfaces(
                from: pane,
                baseCwd: baseCwd,
                unsupportedSurfaceCount: &unsupportedSurfaceCount
            )
            return .pane(CmuxPaneDefinition(surfaces: surfaces.isEmpty ? [CmuxSurfaceDefinition(type: .terminal)] : surfaces))
        }
    }

    private func captureSurfaces(
        from pane: ExternalPaneNode,
        baseCwd: String,
        unsupportedSurfaceCount: inout Int
    ) -> [CmuxSurfaceDefinition] {
        guard let paneUUID = UUID(uuidString: pane.id) else {
            unsupportedSurfaceCount += pane.tabs.count
            return []
        }
        var surfaces: [CmuxSurfaceDefinition] = []
        surfaces.reserveCapacity(max(pane.tabs.count, 1))
        for tab in bonsplitController.tabs(inPane: PaneID(id: paneUUID)) {
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let panel = panels[panelId] else {
                unsupportedSurfaceCount += 1
                surfaces.append(CmuxSurfaceDefinition(type: .terminal))
                continue
            }
            surfaces.append(
                captureSurfaceDefinition(
                    panelId: panelId,
                    panel: panel,
                    baseCwd: baseCwd,
                    unsupportedSurfaceCount: &unsupportedSurfaceCount
                )
            )
        }
        return surfaces
    }

    private func captureSurfaceDefinition(
        panelId: UUID,
        panel: any Panel,
        baseCwd: String,
        unsupportedSurfaceCount: inout Int
    ) -> CmuxSurfaceDefinition {
        var definition: CmuxSurfaceDefinition
        switch panel.panelType {
        case .terminal:
            definition = CmuxSurfaceDefinition(
                type: .terminal,
                name: savedLayoutPanelName(panelId),
                command: nil,
                cwd: savedLayoutTerminalCwd(panelId: panelId, baseCwd: baseCwd),
                env: nil,
                url: nil,
                focus: nil
            )
        case .browser:
            definition = CmuxSurfaceDefinition(
                type: .browser,
                name: savedLayoutPanelName(panelId),
                command: nil,
                cwd: nil,
                env: nil,
                url: browserPanel(for: panelId)?.currentURL?.absoluteString,
                focus: nil
            )
        case .project:
            definition = CmuxSurfaceDefinition(
                type: .project,
                name: savedLayoutPanelName(panelId),
                command: nil,
                cwd: nil,
                env: nil,
                url: nil,
                focus: nil
            )
        case .markdown, .filePreview, .rightSidebarTool, .customSidebar, .agentSession, .extensionBrowser:
            unsupportedSurfaceCount += 1
            definition = CmuxSurfaceDefinition(type: .terminal)
        }
        if focusedPanelId == panelId {
            definition.focus = true
        }
        return definition
    }

    private func savedLayoutPanelName(_ panelId: UUID) -> String? {
        let trimmed = panelCustomTitles[panelId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func savedLayoutTerminalCwd(panelId: UUID, baseCwd: String) -> String? {
        let candidates = [
            panelDirectories[panelId],
            terminalPanel(for: panelId)?.directory,
            terminalPanel(for: panelId)?.requestedWorkingDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            return trimmed == baseCwd ? nil : trimmed
        }
        return nil
    }

    private static func clampedSavedLayoutSplit(_ value: Double) -> Double {
        min(0.9, max(0.1, value))
    }
}

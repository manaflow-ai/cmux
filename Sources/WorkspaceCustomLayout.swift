import Bonsplit
import CoreGraphics
import Foundation
import OSLog

private let workspaceCustomLayoutLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "WorkspaceCustomLayout"
)

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
                workspaceCustomLayoutLogger.warning(
                    "Split node requires exactly 2 children, got \(split.children.count, privacy: .public)"
                )
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
            // Placeholder can't change cwd/env; replace it.
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
            if let panel = newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: false,
                creationPolicy: .restoration
            ) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }

        case .markdown:
            guard let filePath = resolvedMarkdownPath(for: surface, baseCwd: baseCwd) else { return }
            if let panel = newMarkdownSurface(
                inPane: paneId,
                filePath: filePath,
                focus: false
            ) {
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
            if let panel = newBrowserSurface(
                inPane: paneId,
                url: url,
                focus: false,
                creationPolicy: .restoration
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }

        case .markdown:
            guard let filePath = resolvedMarkdownPath(for: surface, baseCwd: baseCwd) else { return }
            if let panel = newMarkdownSurface(
                inPane: paneId,
                filePath: filePath,
                focus: false
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }
        }
    }

    private func resolvedMarkdownPath(
        for surface: CmuxSurfaceDefinition,
        baseCwd: String
    ) -> String? {
        guard let rawPath = surface.path else {
            workspaceCustomLayoutLogger.warning("Markdown surface missing path")
            return nil
        }

        let resolvedPath = CmuxReadableFilePathResolver.resolve(rawPath, relativeTo: baseCwd)
        if let failure = resolvedPath.failure {
            workspaceCustomLayoutLogger.warning(
                "Markdown surface path invalid: \(failure.code, privacy: .public)"
            )
            return nil
        }
        return resolvedPath.path
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
}

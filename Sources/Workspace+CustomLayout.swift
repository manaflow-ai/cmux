import AppKit
import Bonsplit
import Foundation

// MARK: - cmux.json custom layout

extension Workspace {

    func applyCustomLayout(_ layout: CmuxLayoutNode, baseCwd: String, setupCommand: String? = nil) {
        guard let rootPaneId = bonsplitController.allPaneIds.first else { return }

        var leaves: [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition])] = []
        buildCustomLayoutTree(layout, inPane: rootPaneId, leaves: &leaves)

        // First leaf reuses the initial terminal created by addWorkspace;
        // subsequent leaves were created via newTerminalSplit which also seeds
        // a placeholder terminal.
        var focusPanelId: UUID?
        var pendingSetup = setupCommand
        for leaf in leaves {
            populateCustomPane(
                leaf.paneId,
                surfaces: leaf.surfaces,
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId,
                pendingSetup: &pendingSetup
            )
        }

        let liveRoot = bonsplitController.treeSnapshot()
        applyCustomDividerPositions(configNode: layout, liveNode: liveRoot)

        if let focusPanelId {
            focusPanel(focusPanelId)
        }
    }

    /// Sends a config-defined workspace `setup` command to the first terminal
    /// panel. Used by workspace actions/commands that define no custom layout.
    func sendConfigSetupCommand(_ command: String) {
        let firstTerminal: TerminalPanel? = focusedTerminalPanel ?? {
            for paneId in bonsplitController.allPaneIds {
                for tab in bonsplitController.tabs(inPane: paneId) {
                    if let panelId = panelIdFromSurfaceId(tab.id),
                       let terminal = terminalPanel(for: panelId) {
                        return terminal
                    }
                }
            }
            return nil
        }()
        guard let firstTerminal else { return }
        sendInputWhenReady(command + "\n", to: firstTerminal)
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
                #if DEBUG
                NSLog("[CmuxConfig] split node requires exactly 2 children, got %d", split.children.count)
                #endif
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
        focusPanelId: inout UUID?,
        pendingSetup: inout String?
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }

        guard !surfaces.isEmpty else { return }

        var orderedPanelIds: [UUID] = []
        let firstSurface = surfaces[0]
        if let placeholderPanelId = existingPanelIds.first {
            if let panelId = configureExistingSurface(
                panelId: placeholderPanelId,
                inPane: paneId,
                surface: firstSurface,
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId,
                pendingSetup: &pendingSetup
            ) {
                orderedPanelIds.append(panelId)
            }
        }

        for surfaceIndex in 1..<surfaces.count {
            if let panelId = createNewSurface(
                inPane: paneId,
                surface: surfaces[surfaceIndex],
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId,
                pendingSetup: &pendingSetup
            ) {
                orderedPanelIds.append(panelId)
            }
        }

        applyDeclaredSurfaceOrder(orderedPanelIds, inPane: paneId)
    }

    /// Consumes the workspace-level setup command on the first terminal surface it
    /// reaches, sequencing it ahead of that surface's own `command`.
    private static func dequeueInitialTerminalInput(
        pendingSetup: inout String?,
        command: String?
    ) -> String? {
        var lines: [String] = []
        if let setup = pendingSetup {
            lines.append(setup)
            pendingSetup = nil
        }
        if let command {
            lines.append(command)
        }
        guard !lines.isEmpty else { return nil }
        return lines.map { $0 + "\n" }.joined()
    }

    private func configureExistingSurface(
        panelId: UUID,
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?,
        pendingSetup: inout String?
    ) -> UUID? {
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
                if let input = Self.dequeueInitialTerminalInput(pendingSetup: &pendingSetup, command: surface.command) {
                    sendInputWhenReady(input, to: panel)
                }
                return panel.id
            }
            return nil

        case .terminal:
            if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
            if surface.focus == true { focusPanelId = panelId }
            if let input = Self.dequeueInitialTerminalInput(pendingSetup: &pendingSetup, command: surface.command),
               let terminal = terminalPanel(for: panelId) {
                sendInputWhenReady(input, to: terminal)
            }
            return panelId

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
                return panel.id
            }
            return nil

        case .project:
            if let panel = newProjectSurface(
                inPane: paneId,
                projectPath: CmuxConfigStore.resolveCwd(surface.url ?? surface.cwd, relativeTo: baseCwd),
                focus: false
            ) {
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
                return panel.id
            }
            return nil
        }
    }

    private func createNewSurface(
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?,
        pendingSetup: inout String?
    ) -> UUID? {
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
                if let input = Self.dequeueInitialTerminalInput(pendingSetup: &pendingSetup, command: surface.command) {
                    sendInputWhenReady(input, to: panel)
                }
                return panel.id
            }
            return nil

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
                return panel.id
            }
            return nil

        case .project:
            if let panel = newProjectSurface(
                inPane: paneId,
                projectPath: CmuxConfigStore.resolveCwd(surface.url ?? surface.cwd, relativeTo: baseCwd),
                focus: false
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
                return panel.id
            }
            return nil
        }
    }

    /// Reconciles Bonsplit's interactive insertion policy with the declarative
    /// order owned by the layout, without changing the user's new-tab behavior.
    private func applyDeclaredSurfaceOrder(_ panelIds: [UUID], inPane paneId: PaneID) {
        let selectedTabId = bonsplitController.selectedTab(inPane: paneId)?.id
        let focusedPaneId = bonsplitController.focusedPaneId
        var didReorder = false

        for (targetIndex, panelId) in panelIds.enumerated() {
            guard let tabId = surfaceIdFromPanelId(panelId) else { continue }
            let tabs = bonsplitController.tabs(inPane: paneId)
            guard let currentIndex = tabs.firstIndex(where: { $0.id == tabId }),
                  currentIndex != targetIndex else {
                continue
            }
            _ = bonsplitController.reorderTab(tabId, toIndex: targetIndex)
            didReorder = true
        }

        guard didReorder else { return }
        if let selectedTabId,
           bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == selectedTabId }) {
            bonsplitController.selectTab(selectedTabId)
        }
        if let focusedPaneId, bonsplitController.focusedPaneId != focusedPaneId {
            bonsplitController.focusPane(focusedPaneId)
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
}

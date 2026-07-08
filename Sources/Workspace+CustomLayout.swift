import AppKit
import Bonsplit
import Foundation

// MARK: - cmux.json custom layout

extension Workspace {

    func applyCustomLayout(_ layout: CmuxLayoutNode, baseCwd: String, setupCommand: String? = nil) {
        guard let rootPaneId = bonsplitController.allPaneIds.first else { return }

        var leaves: [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition], layoutPath: String)] = []
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
                layoutPath: leaf.layoutPath,
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
        layoutPath: String = "root",
        leaves: inout [(paneId: PaneID, surfaces: [CmuxSurfaceDefinition], layoutPath: String)]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append((paneId: paneId, surfaces: pane.surfaces, layoutPath: layoutPath))

        case .split(let split):
            guard split.children.count == 2 else {
                #if DEBUG
                NSLog("[CmuxConfig] split node requires exactly 2 children, got %d", split.children.count)
                #endif
                leaves.append((paneId: paneId, surfaces: [], layoutPath: layoutPath))
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
                leaves.append((paneId: paneId, surfaces: [], layoutPath: layoutPath))
                return
            }

            buildCustomLayoutTree(
                split.children[0],
                inPane: paneId,
                layoutPath: "\(layoutPath).0",
                leaves: &leaves
            )
            buildCustomLayoutTree(
                split.children[1],
                inPane: secondPaneId,
                layoutPath: "\(layoutPath).1",
                leaves: &leaves
            )
        }
    }

    private func populateCustomPane(
        _ paneId: PaneID,
        surfaces: [CmuxSurfaceDefinition],
        layoutPath: String,
        baseCwd: String,
        focusPanelId: inout UUID?,
        pendingSetup: inout String?
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
                surfaceSeed: "\(layoutPath).surface.0",
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId,
                pendingSetup: &pendingSetup
            )
        }

        for surfaceIndex in 1..<surfaces.count {
            createNewSurface(
                inPane: paneId,
                surface: surfaces[surfaceIndex],
                surfaceSeed: "\(layoutPath).surface.\(surfaceIndex)",
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId,
                pendingSetup: &pendingSetup
            )
        }
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
        surfaceSeed: String,
        baseCwd: String,
        focusPanelId: inout UUID?,
        pendingSetup: inout String?
    ) {
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
            }

        case .terminal:
            if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
            if surface.focus == true { focusPanelId = panelId }
            if let input = Self.dequeueInitialTerminalInput(pendingSetup: &pendingSetup, command: surface.command),
               let terminal = terminalPanel(for: panelId) {
                sendInputWhenReady(input, to: terminal)
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

        case .note:
            let slug = noteSlugForConfigSurface(surface, fallbackSeed: surfaceSeed)
            scheduleConfigNoteSurface(
                replacingPanelId: panelId,
                inPane: paneId,
                slug: slug,
                customTitle: surface.name,
                shouldFocus: surface.focus == true
            )

        case .project:
            if let panel = newProjectSurface(
                inPane: paneId,
                projectPath: CmuxConfigStore.resolveCwd(surface.url ?? surface.cwd, relativeTo: baseCwd),
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
        surfaceSeed: String,
        baseCwd: String,
        focusPanelId: inout UUID?,
        pendingSetup: inout String?
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
                if let input = Self.dequeueInitialTerminalInput(pendingSetup: &pendingSetup, command: surface.command) {
                    sendInputWhenReady(input, to: panel)
                }
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

        case .note:
            let slug = noteSlugForConfigSurface(surface, fallbackSeed: surfaceSeed)
            scheduleConfigNoteSurface(
                replacingPanelId: nil,
                inPane: paneId,
                slug: slug,
                customTitle: surface.name,
                shouldFocus: surface.focus == true
            )

        case .project:
            if let panel = newProjectSurface(
                inPane: paneId,
                projectPath: CmuxConfigStore.resolveCwd(surface.url ?? surface.cwd, relativeTo: baseCwd),
                focus: false
            ) {
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            }
        }
    }

    private func scheduleConfigNoteSurface(
        replacingPanelId placeholderPanelId: UUID?,
        inPane paneId: PaneID,
        slug: String,
        customTitle: String?,
        shouldFocus: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let placeholderPanelId, panels[placeholderPanelId] == nil {
                return
            }
            guard let panel = await newNoteSurface(
                inPane: paneId,
                slug: slug,
                createIfMissing: true,
                focus: false,
                reuseExisting: false
            ) else {
                return
            }
            if let placeholderPanelId {
                _ = closePanel(placeholderPanelId, force: true)
            }
            if let customTitle {
                setPanelCustomTitle(panelId: panel.id, title: customTitle)
            }
            if shouldFocus {
                focusPanel(panel.id)
            }
        }
    }

    /// Resolve a note slug from a config-declared `note` surface. The slug
    /// source-of-truth is `surface.name`; when missing or invalid we derive a
    /// stable slug from the surface's config position so repeated reloads open
    /// the same note file.
    private func noteSlugForConfigSurface(
        _ surface: CmuxSurfaceDefinition,
        fallbackSeed: String
    ) -> String {
        if let raw = surface.name,
           let validated = try? NoteSupport.validateSlug(raw) {
            return validated
        }
        return NoteSupport.configFallbackSlug(seed: fallbackSeed)
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

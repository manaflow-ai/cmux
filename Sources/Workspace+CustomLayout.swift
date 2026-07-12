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

    /// Runs a config-defined workspace `setup` command as the first terminal's
    /// process when possible; falls back to typed input only if the panel already
    /// has a startup command of its own.
    func sendConfigSetupCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
        // Prefer process-as-command when the initial terminal has no command yet.
        // Create the replacement in the pane that actually hosts firstTerminal
        // (not focusedPaneId — focus may be on a browser/project in another pane).
        if firstTerminal.surface.initialCommand == nil {
            let processCommand = TerminalProcessCommand.asInitialProcess(trimmed)
            let cwd = firstTerminal.requestedWorkingDirectory
            let targetPaneId = paneId(forPanelId: firstTerminal.id)
                ?? bonsplitController.focusedPaneId
                ?? bonsplitController.allPaneIds.first
            // Preserve the workspace env the original panel was seeded with.
            // newTerminalSurface also merges current workspaceEnvironment; this
            // keeps any values that were present on the original seed path.
            if let targetPaneId,
               let panel = newTerminalSurface(
                    inPane: targetPaneId,
                    focus: false,
                    workingDirectory: cwd,
                    initialCommand: processCommand,
                    startupEnvironment: firstTerminal.seededWorkspaceEnvironment
               ) {
                _ = closePanel(firstTerminal.id, force: true)
                focusPanel(panel.id)
                return
            }
        }
        sendInputWhenReady(trimmed + "\n", to: firstTerminal)
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

        let firstSurface = surfaces[0]
        if let placeholderPanelId = existingPanelIds.first {
            configureExistingSurface(
                panelId: placeholderPanelId,
                inPane: paneId,
                surface: firstSurface,
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId,
                pendingSetup: &pendingSetup
            )
        }

        for surfaceIndex in 1..<surfaces.count {
            createNewSurface(
                inPane: paneId,
                surface: surfaces[surfaceIndex],
                baseCwd: baseCwd,
                focusPanelId: &focusPanelId,
                pendingSetup: &pendingSetup
            )
        }
    }

    /// Consumes the workspace-level setup command on the first terminal surface it
    /// reaches, sequencing it ahead of that surface's own `command`.
    /// Returns keystroke-oriented input (legacy); prefer ``buildInitialProcessCommand``
    /// for process-as-command launches.
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

    /// Builds a portable process-as-command for layout terminal surfaces.
    /// Does **not** mutate `pendingSetup` — callers clear it only after a successful
    /// surface creation so a failed create can retry setup on a later surface.
    /// Setup and surface commands are joined with newlines (legacy semantics) so a
    /// trailing `#` comment on setup cannot swallow the surface command.
    private static func buildInitialProcessCommand(
        setup: String?,
        command: String?
    ) -> String? {
        var parts: [String] = []
        if let setup = setup?.trimmingCharacters(in: .whitespacesAndNewlines), !setup.isEmpty {
            parts.append(setup)
        }
        if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            parts.append(command)
        }
        guard !parts.isEmpty else { return nil }
        let script = parts.joined(separator: "\n")
        return TerminalProcessCommand.asInitialProcess(script)
    }

    /// Clears `pendingSetup` after a successful process-as-command launch that
    /// incorporated it. No-op when setup was empty or was not part of the launch.
    private static func consumePendingSetupIfUsed(
        _ pendingSetup: inout String?,
        processCommand: String?
    ) {
        guard processCommand != nil else { return }
        guard let setup = pendingSetup?.trimmingCharacters(in: .whitespacesAndNewlines),
              !setup.isEmpty else { return }
        pendingSetup = nil
    }

    private func configureExistingSurface(
        panelId: UUID,
        inPane paneId: PaneID,
        surface: CmuxSurfaceDefinition,
        baseCwd: String,
        focusPanelId: inout UUID?,
        pendingSetup: inout String?
    ) {
        switch surface.type {
        case .terminal where surface.cwd != nil || surface.env != nil:
            // Placeholder can't change cwd/env — replace it
            let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            let processCommand = Self.buildInitialProcessCommand(
                setup: pendingSetup,
                command: surface.command
            )
            if let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                initialCommand: processCommand,
                startupEnvironment: surface.env ?? [:]
            ) {
                Self.consumePendingSetupIfUsed(&pendingSetup, processCommand: processCommand)
                _ = closePanel(panelId, force: true)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
            } else {
                // Replace failed: keep placeholder and type setup/command so work is not lost.
                if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
                if surface.focus == true { focusPanelId = panelId }
                if let input = Self.dequeueInitialTerminalInput(
                    pendingSetup: &pendingSetup,
                    command: surface.command
                ), let terminal = terminalPanel(for: panelId) {
                    sendInputWhenReady(input, to: terminal)
                }
            }

        case .terminal:
            let processCommand = Self.buildInitialProcessCommand(
                setup: pendingSetup,
                command: surface.command
            )
            if let processCommand {
                // Replace placeholder with a process-as-command terminal so layout
                // `command` does not race interactive shell startup.
                let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
                if let panel = newTerminalSurface(
                    inPane: paneId,
                    focus: false,
                    workingDirectory: resolvedCwd,
                    initialCommand: processCommand,
                    startupEnvironment: surface.env ?? [:]
                ) {
                    Self.consumePendingSetupIfUsed(&pendingSetup, processCommand: processCommand)
                    _ = closePanel(panelId, force: true)
                    if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                    if surface.focus == true { focusPanelId = panel.id }
                } else {
                    // Process replace failed: fall back to typed input on the placeholder
                    // so single-pane layouts do not silently drop setup/command.
                    if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
                    if surface.focus == true { focusPanelId = panelId }
                    if let input = Self.dequeueInitialTerminalInput(
                        pendingSetup: &pendingSetup,
                        command: surface.command
                    ), let terminal = terminalPanel(for: panelId) {
                        sendInputWhenReady(input, to: terminal)
                    }
                }
            } else {
                if let name = surface.name { setPanelCustomTitle(panelId: panelId, title: name) }
                if surface.focus == true { focusPanelId = panelId }
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
        baseCwd: String,
        focusPanelId: inout UUID?,
        pendingSetup: inout String?
    ) {
        switch surface.type {
        case .terminal:
            let resolvedCwd = CmuxConfigStore.resolveCwd(surface.cwd, relativeTo: baseCwd)
            let processCommand = Self.buildInitialProcessCommand(
                setup: pendingSetup,
                command: surface.command
            )
            if let panel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: resolvedCwd,
                initialCommand: processCommand,
                startupEnvironment: surface.env ?? [:]
            ) {
                Self.consumePendingSetupIfUsed(&pendingSetup, processCommand: processCommand)
                if let name = surface.name { setPanelCustomTitle(panelId: panel.id, title: name) }
                if surface.focus == true { focusPanelId = panel.id }
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

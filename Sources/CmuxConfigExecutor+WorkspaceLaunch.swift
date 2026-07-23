import AppKit
import Foundation

// MARK: - Workspace command launch (named and inline `type: "workspace"` actions)

extension CmuxConfigExecutor {

    /// The trust dialog must disclose everything a workspace action does to
    /// the shells it spawns — the `setup` bootstrap, each surface `command`,
    /// env assignments (ZDOTDIR/BASH_ENV/PATH-style keys change what
    /// executes), and the cwd values commands run in — not just the action's
    /// (arbitrary, benign-looking) name.
    static func workspaceShellDisclosure(_ command: CmuxCommandDefinition) -> String {
        guard let workspace = command.workspace else { return command.name }
        var shellLines: [String] = []
        if let cwd = workspace.cwd {
            shellLines.append(String(format: Self.cwdDisclosureFormat, cwd))
        }
        if let setup = workspace.setup {
            // Setup runs in the first terminal surface, whose own cwd wins
            // over the workspace cwd — disclose the one that actually applies.
            if let setupCwd = workspace.layout.flatMap(firstTerminalSurfaceCwd) {
                shellLines.append(String(format: Self.cwdCommandDisclosureFormat, setupCwd, setup))
            } else {
                shellLines.append(setup)
            }
        }
        if let workspaceEnv = workspace.env {
            shellLines.append(contentsOf: envDisclosureLines(workspaceEnv))
        }
        if let layout = workspace.layout {
            collectSurfaceDisclosures(layout, into: &shellLines)
        }
        guard !shellLines.isEmpty else { return command.name }
        return ([command.name] + shellLines).joined(separator: "\n")
    }

    private static var cwdDisclosureFormat: String {
        String(localized: "dialog.cmuxConfig.disclosure.cwd", defaultValue: "cwd: %@")
    }

    private static var cwdCommandDisclosureFormat: String {
        String(localized: "dialog.cmuxConfig.disclosure.cwdCommand", defaultValue: "cwd %1$@: %2$@")
    }

    private static var urlDisclosureFormat: String {
        String(localized: "dialog.cmuxConfig.disclosure.url", defaultValue: "url: %@")
    }

    private static func envDisclosureLines(_ env: [String: String]) -> [String] {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// The cwd of the first terminal surface in leaf order — the surface that
    /// receives the `setup` command in `applyCustomLayout`.
    private static func firstTerminalSurfaceCwd(_ node: CmuxLayoutNode) -> String? {
        firstTerminalSurface(node)?.cwd
    }

    private static func firstTerminalSurface(_ node: CmuxLayoutNode) -> CmuxSurfaceDefinition? {
        switch node {
        case .pane(let pane):
            return pane.surfaces.first { $0.type == .terminal }
        case .split(let split):
            for child in split.children {
                if let surface = firstTerminalSurface(child) {
                    return surface
                }
            }
            return nil
        }
    }

    private static func collectSurfaceDisclosures(_ node: CmuxLayoutNode, into lines: inout [String]) {
        switch node {
        case .pane(let pane):
            for surface in pane.surfaces {
                if let command = surface.command {
                    if let cwd = surface.cwd {
                        lines.append(String(format: cwdCommandDisclosureFormat, cwd, command))
                    } else {
                        lines.append(command)
                    }
                } else if let cwd = surface.cwd {
                    lines.append(String(format: cwdDisclosureFormat, cwd))
                }
                if let url = surface.url {
                    // Browser/project surfaces open these on run; URLs can
                    // carry private query strings.
                    lines.append(String(format: urlDisclosureFormat, url))
                }
                if let env = surface.env {
                    lines.append(contentsOf: envDisclosureLines(env))
                }
            }
        case .split(let split):
            for child in split.children {
                collectSurfaceDisclosures(child, into: &lines)
            }
        }
    }


    static func executeWorkspaceCommand(
        command: CmuxCommandDefinition,
        workspace wsDef: CmuxWorkspaceDefinition,
        tabManager: TabManager,
        baseCwd: String,
        sourceWorkspaceID: UUID? = nil,
        select: Bool = true
    ) -> Bool {
        executeWorkspaceCommandOutcome(
            command: command,
            workspace: wsDef,
            tabManager: tabManager,
            baseCwd: baseCwd,
            sourceWorkspaceID: sourceWorkspaceID,
            select: select
        ).isAccepted
    }

    static func executeWorkspaceCommandOutcome(
        command: CmuxCommandDefinition,
        workspace wsDef: CmuxWorkspaceDefinition,
        tabManager: TabManager,
        baseCwd: String,
        sourceWorkspaceID: UUID? = nil,
        select: Bool = true,
        presentingWindow: NSWindow? = nil,
        alertFactory: @MainActor () -> NSAlert = { NSAlert() },
        isExecutionTargetAvailable: @escaping @MainActor () -> Bool = { true },
        onExecuted: (() -> Void)? = nil
    ) -> CmuxConfiguredActionExecutionOutcome {
        guard isExecutionTargetAvailable() else { return .failed }
        let workspaceName = wsDef.name ?? command.name
        let restart = command.restart ?? .new
        var existingWorkspaceToClose: Workspace?

        if let existing = tabManager.tabs.first(where: { $0.customTitle == workspaceName }) {
            switch restart {
            case .new:
                break
            case .ignore:
                if select {
                    tabManager.selectWorkspace(existing)
                }
                onExecuted?()
                return .completed
            case .recreate:
                existingWorkspaceToClose = existing
            case .confirm:
                guard let presentingWindow else { return .failed }
                let alert = makeWorkspaceRestartAlert(alertFactory: alertFactory)
                let existingWorkspaceID = existing.id
                alert.beginSheetModal(for: presentingWindow) { response in
                    guard isExecutionTargetAvailable() else { return }
                    guard response == .alertFirstButtonReturn else {
                        if select,
                           let existing = tabManager.tabs.first(where: { $0.id == existingWorkspaceID }) {
                            tabManager.selectWorkspace(existing)
                        }
                        return
                    }
                    let currentWorkspaceToClose = tabManager.tabs.first {
                        $0.customTitle == workspaceName
                    }
                    createWorkspace(
                        definition: wsDef,
                        workspaceName: workspaceName,
                        tabManager: tabManager,
                        baseCwd: baseCwd,
                        sourceWorkspaceID: sourceWorkspaceID,
                        select: select,
                        existingWorkspaceToClose: currentWorkspaceToClose
                    )
                    onExecuted?()
                }
                return .presented
            }
        }

        createWorkspace(
            definition: wsDef,
            workspaceName: workspaceName,
            tabManager: tabManager,
            baseCwd: baseCwd,
            sourceWorkspaceID: sourceWorkspaceID,
            select: select,
            existingWorkspaceToClose: existingWorkspaceToClose
        )
        onExecuted?()
        return .completed
    }

    private static func makeWorkspaceRestartAlert(
        alertFactory: @MainActor () -> NSAlert
    ) -> NSAlert {
        let alert = alertFactory()
        alert.messageText = String(
            localized: "dialog.cmuxConfig.confirmRestart.title",
            defaultValue: "Workspace Already Exists"
        )
        alert.informativeText = String(
            localized: "dialog.cmuxConfig.confirmRestart.message",
            defaultValue: "A workspace with this name already exists. Close it and create a new one?"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmRestart.recreate",
            defaultValue: "Recreate"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmRestart.cancel",
            defaultValue: "Cancel"
        ))
        return alert
    }

    private static func createWorkspace(
        definition wsDef: CmuxWorkspaceDefinition,
        workspaceName: String,
        tabManager: TabManager,
        baseCwd: String,
        sourceWorkspaceID: UUID?,
        select: Bool,
        existingWorkspaceToClose: Workspace?
    ) {
        let resolvedCwd = CmuxConfigStore.resolveCwd(wsDef.cwd, relativeTo: baseCwd)
        let newWorkspace = tabManager.addWorkspace(
            workingDirectory: resolvedCwd,
            workspaceEnvironment: wsDef.env ?? [:],
            select: select,
            sourceWorkspaceID: sourceWorkspaceID
        )
        newWorkspace.setCustomTitle(workspaceName)
        if let color = wsDef.color {
            newWorkspace.setCustomColor(color)
        }

        if let existingWorkspaceToClose, existingWorkspaceToClose.id != newWorkspace.id {
            tabManager.closeWorkspace(existingWorkspaceToClose)
        }

        if let layout = wsDef.layout {
            newWorkspace.applyCustomLayout(layout, baseCwd: resolvedCwd, setupCommand: wsDef.setup)
        } else if let setup = wsDef.setup {
            newWorkspace.sendConfigSetupCommand(setup)
        }
    }
}

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
            shellLines.append("cwd: \(cwd)")
        }
        if let setup = workspace.setup {
            shellLines.append(setup)
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

    private static func envDisclosureLines(_ env: [String: String]) -> [String] {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    private static func collectSurfaceDisclosures(_ node: CmuxLayoutNode, into lines: inout [String]) {
        switch node {
        case .pane(let pane):
            for surface in pane.surfaces {
                if let command = surface.command {
                    if let cwd = surface.cwd {
                        lines.append("cwd \(cwd): \(command)")
                    } else {
                        lines.append(command)
                    }
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
        baseCwd: String
    ) -> Bool {
        let workspaceName = wsDef.name ?? command.name
        let restart = command.restart ?? .new
        var existingWorkspaceToClose: Workspace?

        if let existing = tabManager.tabs.first(where: { $0.customTitle == workspaceName }) {
            switch restart {
            case .new:
                break
            case .ignore:
                tabManager.selectWorkspace(existing)
                return true
            case .recreate:
                existingWorkspaceToClose = existing
            case .confirm:
                let alert = NSAlert()
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
                guard alert.runModal() == .alertFirstButtonReturn else {
                    tabManager.selectWorkspace(existing)
                    return false
                }
                existingWorkspaceToClose = existing
            }
        }

        let resolvedCwd = CmuxConfigStore.resolveCwd(wsDef.cwd, relativeTo: baseCwd)
        let newWorkspace = tabManager.addWorkspace(
            workingDirectory: resolvedCwd,
            workspaceEnvironment: wsDef.env ?? [:]
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
        return true
    }
}

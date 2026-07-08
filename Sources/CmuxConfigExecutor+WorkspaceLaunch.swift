import AppKit
import CmuxWorkspaces
import Foundation

// MARK: - Workspace command launch (named and inline `type: "workspace"` actions)

extension CmuxConfigExecutor {
    private typealias ConfigLayoutNode = CmuxWorkspaces.CmuxLayoutNode
    private typealias ConfigSurfaceDefinition = CmuxWorkspaces.CmuxSurfaceDefinition
    private typealias ConfigWorkspaceDefinition = CmuxWorkspaces.CmuxWorkspaceDefinition

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
    private static func firstTerminalSurfaceCwd(_ node: ConfigLayoutNode) -> String? {
        firstTerminalSurface(node)?.cwd
    }

    private static func firstTerminalSurface(_ node: ConfigLayoutNode) -> ConfigSurfaceDefinition? {
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

    private static func collectSurfaceDisclosures(_ node: ConfigLayoutNode, into lines: inout [String]) {
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
        workspace wsDef: CmuxWorkspaces.CmuxWorkspaceDefinition,
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

    @discardableResult
    static func executeBrowserWorkspaceCommand(
        name: String,
        url: String,
        tabManager: TabManager,
        baseCwd: String
    ) -> Bool {
        let workspaceDefinition = CmuxWorkspaces.CmuxWorkspaceDefinition(
            name: name,
            layout: .pane(CmuxWorkspaces.CmuxPaneDefinition(surfaces: [
                CmuxWorkspaces.CmuxSurfaceDefinition(
                    type: .browser,
                    name: name,
                    url: url,
                    focus: true
                ),
            ]))
        )
        let command = CmuxCommandDefinition(
            name: name,
            workspace: workspaceDefinition
        )
        return executeWorkspaceCommand(
            command: command,
            workspace: workspaceDefinition,
            tabManager: tabManager,
            baseCwd: baseCwd
        )
    }

    static func agentChatStartCommandTrustDescriptor(
        command: String,
        sourcePath: String
    ) -> CmuxActionTrustDescriptor {
        CmuxActionTrustDescriptor(
            actionID: "\(CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID).startCommand",
            kind: "agentChatStartCommand",
            command: command,
            target: "agentChatServer",
            workspaceCommand: nil,
            configPath: canonicalAgentChatPath(sourcePath),
            projectRoot: canonicalAgentChatPath(CmuxButtonIcon.projectRoot(forConfigPath: sourcePath)),
            iconFingerprint: nil
        )
    }

    private static func canonicalAgentChatPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

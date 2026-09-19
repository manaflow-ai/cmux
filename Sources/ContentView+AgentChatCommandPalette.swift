import AppKit
import CmuxCommandPalette
import CmuxTerminal
import Foundation

extension ContentView {
    func commandPaletteConfigActionID(for commandId: String) -> String? {
        switch commandId {
        case "palette.newTerminalTab":
            return CmuxSurfaceTabBarBuiltInAction.newTerminal.configID
        case "palette.newBrowserTab":
            return CmuxSurfaceTabBarBuiltInAction.newBrowser.configID
        case "palette.newSimulatorPane":
            return CmuxSurfaceTabBarBuiltInAction.newSimulator.configID
        case "palette.newAgentChat":
            return CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID
        case "palette.terminalSplitRight":
            return CmuxSurfaceTabBarBuiltInAction.splitRight.configID
        case "palette.terminalSplitDown":
            return CmuxSurfaceTabBarBuiltInAction.splitDown.configID
        default:
            return nil
        }
    }

    static func commandPaletteNewAgentChatContributions() -> [CommandPaletteCommandContribution] {
        guard CmuxFeatureFlags.shared.isAgentChatUIEnabled else { return [] }
        return [CommandPaletteCommandContribution(
            commandId: "palette.newAgentChat",
            title: { _ in String(localized: "command.newAgentChat.title", defaultValue: "New agent chat") },
            subtitle: { _ in String(localized: "command.newAgentChat.subtitle", defaultValue: "Agent Chat") },
            keywords: ["create", "new", "agent", "chat", "browser", "codex", "claude"],
            when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
        )]
    }

    func registerAgentChatCommandPaletteHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newAgentChat") {
            guard CmuxFeatureFlags.shared.isAgentChatUIEnabled else {
                NSSound.beep()
                return
            }
            guard let appDelegate = AppDelegate.shared else {
                NSSound.beep()
                return
            }
            if !appDelegate.executeConfiguredCmuxAction(
                id: CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID,
                tabManager: tabManager,
                preferredWindow: appDelegate.mainWindow(for: windowId)
            ) {
                NSSound.beep()
            }
        }
    }

    static let commandPaletteWorkspaceIsRemoteKey = CommandPaletteContextKeys(
        rawValue: "workspace.isRemote"
    )
    static let commandPaletteLaunchClaudeTeamsCommandID = "palette.launchClaudeTeams"
    static let commandPaletteLaunchCodexTeamsCommandID = "palette.launchCodexTeams"

    static func commandPaletteAgentLauncherContributions(
        claudeTeamsAvailable: Bool? = nil,
        codexTeamsAvailable: Bool? = nil
    ) -> [CommandPaletteCommandContribution] {
        let claudeTeamsAvailable = claudeTeamsAvailable
            ?? commandPaletteAgentLauncherIsAvailable(provider: .claude)
        let codexTeamsAvailable = codexTeamsAvailable
            ?? commandPaletteAgentLauncherIsAvailable(provider: .codex)
        let canLaunchFromCurrentWorkspace: (CommandPaletteContextSnapshot) -> Bool = { snapshot in
            snapshot.bool(CommandPaletteContextKeys.hasWorkspace)
                && !snapshot.bool(commandPaletteWorkspaceIsRemoteKey)
        }

        var contributions: [CommandPaletteCommandContribution] = []
        if claudeTeamsAvailable {
            contributions.append(CommandPaletteCommandContribution(
                commandId: commandPaletteLaunchClaudeTeamsCommandID,
                title: { _ in
                    String(
                        localized: "command.launchClaudeTeams.title",
                        defaultValue: "Launch Claude Teams"
                    )
                },
                subtitle: { _ in
                    String(
                        localized: "command.agentLauncher.subtitle",
                        defaultValue: "Agent Launcher"
                    )
                },
                keywords: ["claude", "claude-teams", "teams", "agent", "launcher"],
                when: canLaunchFromCurrentWorkspace
            ))
        }
        if codexTeamsAvailable {
            contributions.append(CommandPaletteCommandContribution(
                commandId: commandPaletteLaunchCodexTeamsCommandID,
                title: { _ in
                    String(
                        localized: "command.launchCodexTeams.title",
                        defaultValue: "Launch Codex Teams"
                    )
                },
                subtitle: { _ in
                    String(
                        localized: "command.agentLauncher.subtitle",
                        defaultValue: "Agent Launcher"
                    )
                },
                keywords: ["codex", "codex-teams", "teams", "agent", "launcher"],
                when: canLaunchFromCurrentWorkspace
            ))
        }
        return contributions
    }

    static func commandPaletteAgentLauncherIsAvailable(
        provider: AgentSessionProviderID,
        resolver: AgentExecutableResolver? = nil,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let bundleResourceURL else { return false }
        let cliURL = bundleResourceURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cliURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: cliURL.path) else {
            return false
        }

        let resolver = resolver ?? AgentExecutableResolver(
            fileManager: fileManager,
            bundleResourceURL: bundleResourceURL,
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        )
        return (try? resolver.resolve(provider)) != nil
    }

    static func commandPaletteAgentLauncherShellInput(
        cliURL: URL,
        subcommand: String
    ) -> String {
        "\(cliURL.path.terminalShellEscaped) \(subcommand.terminalShellEscaped)\n"
    }

    func registerAgentLauncherCommandPaletteHandlers(
        _ registry: inout CommandPaletteHandlerRegistry
    ) {
        registry.register(commandId: Self.commandPaletteLaunchClaudeTeamsCommandID) {
            launchCommandPaletteAgentLauncher(provider: .claude, subcommand: "claude-teams")
        }
        registry.register(commandId: Self.commandPaletteLaunchCodexTeamsCommandID) {
            launchCommandPaletteAgentLauncher(provider: .codex, subcommand: "codex-teams")
        }
    }

    private func launchCommandPaletteAgentLauncher(
        provider: AgentSessionProviderID,
        subcommand: String
    ) {
        guard let workspace = tabManager.selectedWorkspace,
              !workspace.isRemoteWorkspace,
              let bundleResourceURL = Bundle.main.resourceURL else {
            NSSound.beep()
            return
        }

        let resolver = AgentExecutableResolver(
            bundleResourceURL: bundleResourceURL,
            configuredExecutablePaths: AgentExecutableResolver.cmuxConfiguredExecutablePaths()
        )
        guard Self.commandPaletteAgentLauncherIsAvailable(
            provider: provider,
            resolver: resolver,
            bundleResourceURL: bundleResourceURL
        ) else {
            NSSound.beep()
            return
        }

        let cliURL = bundleResourceURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
        tabManager.newSurface(initialInput: Self.commandPaletteAgentLauncherShellInput(
            cliURL: cliURL,
            subcommand: subcommand
        ))
    }

}

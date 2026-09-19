import AppKit
import CmuxCommandPalette
import CmuxTerminal
import Foundation

extension ContentView {
    /// Maps built-in palette commands back to their configurable action identifiers.
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

    /// Returns the built-in Agent Chat palette contribution when its rollout is enabled.
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

    /// Registers the shared Agent Chat action path with the command palette.
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

    /// Palette context key indicating that the selected workspace is remotely managed.
    static let commandPaletteWorkspaceIsRemoteKey = CommandPaletteContextKeys(
        rawValue: "workspace.isRemote"
    )
    static let commandPaletteLaunchClaudeTeamsCommandID = "palette.launchClaudeTeams"
    static let commandPaletteLaunchCodexTeamsCommandID = "palette.launchCodexTeams"

    /// Builds launcher commands from availability already resolved away from the main actor.
    static func commandPaletteAgentLauncherContributions(
        availableProviders: Set<AgentSessionProviderID>
    ) -> [CommandPaletteCommandContribution] {
        let canLaunchFromCurrentWorkspace: (CommandPaletteContextSnapshot) -> Bool = { snapshot in
            snapshot.bool(CommandPaletteContextKeys.hasWorkspace)
                && !snapshot.bool(commandPaletteWorkspaceIsRemoteKey)
        }

        var contributions: [CommandPaletteCommandContribution] = []
        if availableProviders.contains(.claude) {
            contributions.append(CommandPaletteCommandContribution(
                commandId: commandPaletteLaunchClaudeTeamsCommandID,
                title: { _ in
                    String(
                        localized: "agentSession.provider.claude",
                        defaultValue: "Claude Code"
                    )
                },
                subtitle: { _ in "cmux claude-teams" },
                keywords: ["claude", "claude-teams", "teams", "agent", "launcher"],
                when: canLaunchFromCurrentWorkspace
            ))
        }
        if availableProviders.contains(.codex) {
            contributions.append(CommandPaletteCommandContribution(
                commandId: commandPaletteLaunchCodexTeamsCommandID,
                title: { _ in
                    String(
                        localized: "agentSession.provider.codex",
                        defaultValue: "Codex"
                    )
                },
                subtitle: { _ in "cmux codex-teams" },
                keywords: ["codex", "codex-teams", "teams", "agent", "launcher"],
                when: canLaunchFromCurrentWorkspace
            ))
        }
        return contributions
    }

    /// Resolves all palette launcher providers with one shared search-directory scan.
    nonisolated static func commandPaletteAvailableAgentLauncherProviders(
        environment: [String: String],
        bundleResourceURL: URL?,
        configuredExecutablePaths: [AgentSessionProviderID: String],
        fileManager: FileManager = .default,
        includeStandardSearchDirectories: Bool = true
    ) -> Set<AgentSessionProviderID> {
        guard let bundleResourceURL else { return [] }
        let cliURL = bundleResourceURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cliURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: cliURL.path) else {
            return []
        }

        let resolver = AgentExecutableResolver(
            environment: environment,
            fileManager: fileManager,
            bundleResourceURL: bundleResourceURL,
            includeStandardSearchDirectories: includeStandardSearchDirectories,
            configuredExecutablePaths: configuredExecutablePaths
        )
        let searchDirectories = resolver.resolvedSearchDirectories()
        var available: Set<AgentSessionProviderID> = []
        for provider in [AgentSessionProviderID.claude, .codex] {
            if (try? resolver.resolve(provider, searchDirectories: searchDirectories)) != nil {
                available.insert(provider)
            }
        }
        return available
    }

    /// Rechecks one provider immediately before launching its bundled CLI command.
    nonisolated static func commandPaletteAgentLauncherIsAvailable(
        provider: AgentSessionProviderID,
        environment: [String: String],
        bundleResourceURL: URL?,
        configuredExecutablePaths: [AgentSessionProviderID: String],
        fileManager: FileManager = .default,
        includeStandardSearchDirectories: Bool = true
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

        let resolver = AgentExecutableResolver(
            environment: environment,
            fileManager: fileManager,
            bundleResourceURL: bundleResourceURL,
            includeStandardSearchDirectories: includeStandardSearchDirectories,
            configuredExecutablePaths: configuredExecutablePaths
        )
        return (try? resolver.resolve(provider)) != nil
    }

    /// Formats the exact bundled-CLI command injected into the new terminal tab.
    nonisolated static func commandPaletteAgentLauncherShellInput(
        cliURL: URL,
        subcommand: String
    ) -> String {
        "\(cliURL.path.terminalShellEscaped) \(subcommand.terminalShellEscaped)\n"
    }

    /// Registers thin palette handlers that delegate launch ownership to the bundled CLI.
    func registerAgentLauncherCommandPaletteHandlers(
        _ registry: inout CommandPaletteHandlerRegistry
    ) {
        registry.register(commandId: Self.commandPaletteLaunchClaudeTeamsCommandID) {
            startCommandPaletteAgentLauncherActivation(provider: .claude, subcommand: "claude-teams")
        }
        registry.register(commandId: Self.commandPaletteLaunchCodexTeamsCommandID) {
            startCommandPaletteAgentLauncherActivation(provider: .codex, subcommand: "codex-teams")
        }
    }

}

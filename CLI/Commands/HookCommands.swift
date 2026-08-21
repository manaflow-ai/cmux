import ArgumentParser
import Foundation

/// Routes hook and managed-agent launcher declarations through the established CLI implementation.
private protocol LegacyHookCommand: ParsableCommand {}

extension LegacyHookCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

/// Preserves every argument after an agent-launching command for its downstream executable.
private protocol AgentLauncherCommand: LegacyHookCommand {}

extension AgentLauncherCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: commandName, helpNames: [])
    }

    static var commandName: String {
        fatalError("Agent launcher commands must provide a command name")
    }
}

struct HooksCommand: LegacyHookCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "hooks", helpNames: [])
}

/// Backward-compatible shortcut for installing all available hook integrations.
struct SetupHooksCommand: LegacyHookCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "setup-hooks", helpNames: [])
}

/// Backward-compatible shortcut for removing all available hook integrations.
struct UninstallHooksCommand: LegacyHookCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "uninstall-hooks", helpNames: [])
}

/// Hidden compatibility entry point for installed Claude Code hooks.
struct ClaudeHookCommand: LegacyHookCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "claude-hook", shouldDisplay: false, helpNames: [])
}

/// Hidden compatibility entry point for installed Codex hooks.
struct CodexHookCommand: LegacyHookCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "codex-hook", shouldDisplay: false, helpNames: [])
}

/// Hidden compatibility entry point for installed Feed hooks.
struct FeedHookCommand: LegacyHookCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "feed-hook", shouldDisplay: false, helpNames: [])
}

struct ClaudeTeamsCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let commandName = "claude-teams"
}

struct CodexTeamsCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let commandName = "codex-teams"
}

/// Backward-compatible Codex hook installer entry point.
struct CodexCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let commandName = "codex"
}

struct OMOCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let commandName = "omo"
}

struct OMXCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let commandName = "omx"
}

struct OMCCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let commandName = "omc"
}

struct AgentHibernationCommand: LegacyHookCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "agent-hibernation", helpNames: [])
}

struct CoderouterCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(
        commandName: "coderouter",
        abstract: CMUXCLI.localizedCoderouterAliases(),
        helpNames: [],
        aliases: ["cr"]
    )
}

/// Internal Codex Teams watcher launched by the app-server coordinator.
struct CodexTeamsWatchCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(
        commandName: "__codex-teams-watch",
        shouldDisplay: false,
        helpNames: []
    )
}

/// Internal process supervisor handled before normal legacy command dispatch.
struct CodexTeamsAppServerSupervisorCommand: AgentLauncherCommand {
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []
    static let configuration = CommandConfiguration(
        commandName: "__codex-teams-app-server-supervisor",
        shouldDisplay: false,
        helpNames: []
    )
}

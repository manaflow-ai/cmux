import ArgumentParser
import Foundation

/// `cmux claude-account list|switch`. The legacy runner parses and runs it
/// (`CMUXCLI.runClaudeAccount`, `CMUXCLI.runClaudeAccountList`); these
/// declarations drive completion, typo suggestions and the command tree.
struct ClaudeAccountCommand: SharedLegacyFacadeCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-account",
        subcommands: [ClaudeAccountListCommand.self, ClaudeAccountSwitchCommand.self],
        defaultSubcommand: ClaudeAccountListCommand.self,
        helpNames: []
    )
}

struct ClaudeAccountListCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [])
}

struct ClaudeAccountSwitchCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surface: String?
    @Flag(name: .customLong("force")) var force = false
    /// The account name; the legacy parser reads it as the one positional.
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "switch", helpNames: [])
}

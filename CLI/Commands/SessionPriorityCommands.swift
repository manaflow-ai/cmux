import ArgumentParser
import Foundation

/// `cmux session-priority [status]|difficulty|manual`. The legacy runner parses and runs it
/// (`CMUXCLI.runSessionPriority`); these declarations drive completion, typo suggestions and
/// the command tree.
struct SessionPriorityCommand: SharedLegacyFacadeCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-priority",
        subcommands: [
            SessionPriorityStatusCommand.self,
            SessionPriorityDifficultyCommand.self,
            SessionPriorityManualCommand.self
        ],
        defaultSubcommand: SessionPriorityStatusCommand.self,
        helpNames: []
    )
}

struct SessionPriorityStatusCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "status", helpNames: [])
}

struct SessionPriorityDifficultyCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(completion: .list(CMUXCLI.sessionPriorityDifficulties)) var difficulty: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "difficulty", helpNames: [])
}

struct SessionPriorityManualCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(completion: .list(["on", "off"])) var value: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "manual", helpNames: [])
}

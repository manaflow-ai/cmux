import ArgumentParser
import Foundation

/// Routes auth facade declarations back through the established CLI implementation.
private protocol LegacyAuthCommand: ParsableCommand {}

extension LegacyAuthCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

struct AuthCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "auth",
        subcommands: [AuthStatusCommand.self, AuthLoginCommand.self, AuthLogoutCommand.self],
        defaultSubcommand: AuthStatusCommand.self,
        helpNames: []
    )
}

struct AuthStatusCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "status", helpNames: [])
}

struct AuthLoginCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "login", helpNames: [])
}

struct AuthLogoutCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "logout", helpNames: [])
}

/// Declares the established top-level alias without changing its legacy execution path.
struct LoginCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "login", helpNames: [])
}

/// Declares the established top-level alias without changing its legacy execution path.
struct LogoutCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "logout", helpNames: [])
}

struct AIAccountsCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "ai-accounts",
        subcommands: [AIAccountsListCommand.self, AIAccountsUploadCommand.self, AIAccountsRemoveCommand.self],
        defaultSubcommand: AIAccountsListCommand.self,
        helpNames: []
    )
}

struct AIAccountsListCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [])
}

struct AIAccountsUploadCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "upload", helpNames: [])
}

struct AIAccountsRemoveCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "remove", helpNames: [])
}

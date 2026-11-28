import ArgumentParser
import Foundation

/// Routes auth facade declarations back through the established CLI implementation.
private protocol LegacyAuthCommand: SharedLegacyFacadeCommand {}

struct AuthCommand: LegacyAuthCommand {
    // No catch-all argument here: ArgumentParser already generates a rest-argument
    // spec to dispatch into `subcommands`, and a second one on this struct produces
    // an invalid duplicate `_arguments` spec in the generated zsh completion script.
    // `defaultSubcommand` absorbs anything that doesn't name a declared subcommand.
    static let configuration = CommandConfiguration(
        commandName: "auth",
        subcommands: [AuthStatusCommand.self, AuthLoginCommand.self, AuthLogoutCommand.self, AuthTeamCommand.self],
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

struct AuthTeamCommand: LegacyAuthCommand {
    // See AuthCommand's comment: no catch-all argument alongside `subcommands`.
    static let configuration = CommandConfiguration(
        commandName: "team",
        subcommands: [
            AuthTeamListCommand.self,
            AuthTeamUseCommand.self,
            AuthTeamCreateCommand.self,
            AuthTeamMembersCommand.self,
            AuthTeamInviteCommand.self,
            AuthTeamLinkCommand.self,
            AuthTeamRevokeInviteCommand.self,
            AuthTeamInvitationsCommand.self,
            AuthTeamAcceptCommand.self,
            AuthTeamDeclineCommand.self,
            AuthTeamRemoveCommand.self,
        ],
        defaultSubcommand: AuthTeamListCommand.self,
        helpNames: []
    )
}

struct AuthTeamListCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [])
}

struct AuthTeamUseCommand: LegacyAuthCommand {
    @Argument var teamID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "use", helpNames: [])
}

struct AuthTeamCreateCommand: LegacyAuthCommand {
    @Argument var name: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "create", helpNames: [])
}

struct AuthTeamMembersCommand: LegacyAuthCommand {
    @Option(name: .customLong("team")) var team: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "members", helpNames: [])
}

struct AuthTeamInviteCommand: LegacyAuthCommand {
    @Option(name: .customLong("role"), completion: .list(["admin", "member"])) var role: String?
    @Option(name: .customLong("team")) var team: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "invite", helpNames: [])
}

struct AuthTeamLinkCommand: LegacyAuthCommand {
    @Option(name: .customLong("team")) var team: String?
    @Option(name: .customLong("expires-days")) var expiresDays: String?
    @Option(name: .customLong("max-uses")) var maxUses: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "link", helpNames: [])
}

struct AuthTeamRevokeInviteCommand: LegacyAuthCommand {
    @Argument var invitationID: String?
    @Option(name: .customLong("team")) var team: String?
    @Flag(name: .customLong("link")) var link = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "revoke-invite", helpNames: [])
}

struct AuthTeamInvitationsCommand: LegacyAuthCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "invitations", helpNames: [])
}

struct AuthTeamAcceptCommand: LegacyAuthCommand {
    @Argument var invitationID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "accept", helpNames: [])
}

struct AuthTeamDeclineCommand: LegacyAuthCommand {
    @Argument var invitationID: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "decline", helpNames: [])
}

struct AuthTeamRemoveCommand: LegacyAuthCommand {
    @Argument var userID: String?
    @Option(name: .customLong("team")) var team: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "remove", helpNames: [])
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
    // See AuthCommand's comment: no catch-all argument alongside `subcommands`.
    static let configuration = CommandConfiguration(
        commandName: "ai-accounts",
        subcommands: [AIAccountsListCommand.self, AIAccountsUploadCommand.self, AIAccountsRemoveCommand.self],
        defaultSubcommand: AIAccountsListCommand.self,
        helpNames: []
    )
}

struct AIAccountsListCommand: LegacyAuthCommand {
    @Option(name: .customLong("team")) var team: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [], aliases: ["ls"])
}

struct AIAccountsUploadCommand: LegacyAuthCommand {
    @Argument(completion: .list(["claude", "codex", "anthropic-key", "openai-key"])) var provider: String?
    @Option(name: .customLong("label")) var label: String?
    @Option(name: .customLong("key")) var key: String?
    @Option(name: .customLong("team")) var team: String?
    @Flag(name: .customLong("validate")) var validate = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "upload", helpNames: [])
}

struct AIAccountsRemoveCommand: LegacyAuthCommand {
    @Argument var accountID: String?
    @Option(name: .customLong("team")) var team: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "remove", helpNames: [], aliases: ["rm", "delete"])
}

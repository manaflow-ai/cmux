import ArgumentParser
import Foundation

struct NotifyCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("title")) var title: String?
    @Option(name: .customLong("subtitle")) var subtitle: String?
    @Option(name: .customLong("body")) var body: String?
    @Flag(name: .customLong("reply")) var reply = false
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surface: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Flag(name: .customLong("clear")) var clear = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "notify", helpNames: [])
}

struct ListNotificationsCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-notifications", helpNames: [])
}

struct DismissNotificationCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id")) var id: String?
    @Flag(name: .customLong("all-read")) var allRead = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(commandName: "dismiss-notification", helpNames: [])
}

struct MarkNotificationReadCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id")) var id: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surface: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Flag(name: .customLong("all")) var all = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(commandName: "mark-notification-read", helpNames: [])
}

struct OpenNotificationCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id")) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open-notification", helpNames: [])
}

struct JumpToUnreadCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "jump-to-unread", helpNames: [])
}

struct ClearNotificationsCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surface: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-notifications", helpNames: [])
}

struct FeedCommand: SharedLegacyFacadeCommand {
    // No catch-all argument alongside `subcommands`, and no default subcommand:
    // a bare `cmux feed` prints the legacy usage, which no leaf stands for.
    static let configuration = CommandConfiguration(
        commandName: "feed",
        subcommands: [FeedTUICommand.self, FeedClearCommand.self],
        helpNames: []
    )
}

struct FeedTUICommand: SharedLegacyFacadeCommand {
    // The legacy parser rejects the pair together itself.
    @Flag(name: .customLong("opentui")) var opentui = false
    @Flag(name: .customLong("legacy")) var legacy = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "tui", helpNames: [])
}

struct FeedClearCommand: SharedLegacyFacadeCommand {
    @Flag(name: [.customLong("yes"), .customShort("y")]) var yes = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear", helpNames: [])
}

struct EventsCommand: SharedLegacyFacadeCommand {
    @Option(name: [.customLong("after"), .customLong("after-seq")]) var after: String?
    @Option(name: .customLong("cursor-file"), completion: .file()) var cursorFile: String?
    @Option(name: .customLong("name")) var names: [String] = []
    @Option(name: .customLong("category")) var categories: [String] = []
    @Flag(name: .customLong("reconnect")) var reconnect = false
    @Option(name: .customLong("limit")) var limit: String?
    @Option(name: .customLong("timeout")) var timeout: String?
    @Flag(name: .customLong("snapshot")) var snapshot = false
    @Flag(name: .customLong("no-ack")) var noAck = false
    @Flag(name: [.customLong("no-heartbeat"), .customLong("no-heartbeats")]) var noHeartbeat = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "events", helpNames: [])
}

struct LogCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("level"), completion: .list(["info", "progress", "success", "warning", "error"])) var level: String?
    @Option(name: .customLong("source")) var source: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "log", helpNames: [])
}

struct ListLogCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Option(name: .customLong("limit")) var limit: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-log", helpNames: [])
}

struct ClearLogCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-log", helpNames: [])
}

struct SetStatusCommand: SharedLegacyFacadeCommand {
    @Argument var key: String?
    @Argument var value: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Option(name: .customLong("icon")) var icon: String?
    @Option(name: .customLong("color")) var color: String?
    @Option(name: .customLong("priority")) var priority: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-status", helpNames: [])
}

struct ListStatusCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-status", helpNames: [])
}

struct ClearStatusCommand: SharedLegacyFacadeCommand {
    @Argument var key: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-status", helpNames: [])
}

/// Internal shell-integration entrypoints: a terminal's shell hooks forward one
/// piece of sidebar metadata each. Hidden from help and completion.
struct ReportPwdCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "report_pwd", shouldDisplay: false, helpNames: [])
}

struct ReportGitBranchCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "report_git_branch", shouldDisplay: false, helpNames: [])
}

struct ReportPRActionCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "report_pr_action", shouldDisplay: false, helpNames: [])
}

struct SetProgressCommand: SharedLegacyFacadeCommand {
    @Argument var progress: String?
    @Option(name: .customLong("label")) var label: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-progress", helpNames: [])
}

struct ClearProgressCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-progress", helpNames: [])
}

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

    func run() async throws {
        guard (id != nil) != allRead else {
            throw FacadeValidationError(
                message: String(
                    localized: "cli.error.dismissNotificationSelector",
                    defaultValue: "dismiss-notification requires exactly one of --id or --all-read"
                ),
                command: Self.self
            )
        }
        try await GlobalOptions().makeCLI().run()
    }
}

struct MarkNotificationReadCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("id")) var id: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surface: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Flag(name: .customLong("all")) var all = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(commandName: "mark-notification-read", helpNames: [])

    func run() async throws {
        let selectorCount = (id == nil ? 0 : 1) + (workspace == nil ? 0 : 1) + (all ? 1 : 0)
        guard selectorCount == 1 else {
            throw FacadeValidationError(
                message: String(
                    localized: "cli.error.markNotificationReadSelector",
                    defaultValue: "mark-notification-read requires exactly one selector: --id, --workspace, or --all"
                ),
                command: Self.self
            )
        }
        guard surface == nil || workspace != nil else {
            throw FacadeValidationError(
                message: String(
                    localized: "cli.error.markNotificationReadSurfaceRequiresWorkspace",
                    defaultValue: "--surface requires --workspace"
                ),
                command: Self.self
            )
        }
        try await GlobalOptions().makeCLI().run()
    }
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
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-notifications", helpNames: [])
}

struct FeedCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "feed", helpNames: [])
}

struct EventsCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("after")) var after: String?
    @Option(name: .customLong("cursor-file"), completion: .file()) var cursorFile: String?
    @Option(name: .customLong("name")) var names: [String] = []
    @Option(name: .customLong("category")) var categories: [String] = []
    @Flag(name: .customLong("reconnect")) var reconnect = false
    @Option(name: .customLong("limit")) var limit: String?
    @Option(name: .customLong("timeout")) var timeout: String?
    @Flag(name: .customLong("snapshot")) var snapshot = false
    @Flag(name: .customLong("no-ack")) var noAck = false
    @Flag(name: .customLong("no-heartbeat")) var noHeartbeat = false
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

import ArgumentParser
import Foundation

/// Routes notification and sidebar metadata facade declarations through the
/// established CLI implementation.
private protocol LegacyNotificationCommand: ParsableCommand {}

extension LegacyNotificationCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

private protocol NotificationTargetCommand: LegacyNotificationCommand {}

extension NotificationTargetCommand {
    static var workspaceCompletion: CompletionKind { .custom(CompletionCandidates.workspaces) }
    static var surfaceCompletion: CompletionKind { .custom(CompletionCandidates.surfaces) }
    static var windowCompletion: CompletionKind { .custom(CompletionCandidates.windows) }
}

struct NotifyCommand: NotificationTargetCommand {
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

struct ListNotificationsCommand: LegacyNotificationCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-notifications", helpNames: [])
}

struct DismissNotificationCommand: LegacyNotificationCommand {
    @Option(name: .customLong("id")) var id: String?
    @Flag(name: .customLong("all-read")) var allRead = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(commandName: "dismiss-notification", helpNames: [])

    func run() throws {
        guard (id != nil) != allRead else {
            throw FacadeValidationError(
                message: String(
                    localized: "cli.error.dismissNotificationSelector",
                    defaultValue: "dismiss-notification requires exactly one of --id or --all-read"
                ),
                command: Self.self
            )
        }
        try GlobalOptions().makeCLI().run()
    }
}

struct MarkNotificationReadCommand: NotificationTargetCommand {
    @Option(name: .customLong("id")) var id: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surface: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Flag(name: .customLong("all")) var all = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(commandName: "mark-notification-read", helpNames: [])

    func run() throws {
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
        try GlobalOptions().makeCLI().run()
    }
}

struct OpenNotificationCommand: LegacyNotificationCommand {
    @Option(name: .customLong("id")) var id: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "open-notification", helpNames: [])
}

struct JumpToUnreadCommand: LegacyNotificationCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "jump-to-unread", helpNames: [])
}

struct ClearNotificationsCommand: NotificationTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-notifications", helpNames: [])
}

struct FeedCommand: LegacyNotificationCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "feed", helpNames: [])
}

struct EventsCommand: LegacyNotificationCommand {
    @Option(name: .customLong("after")) var after: Int?
    @Option(name: .customLong("cursor-file"), completion: .file()) var cursorFile: String?
    @Option(name: .customLong("name")) var names: [String] = []
    @Option(name: .customLong("category")) var categories: [String] = []
    @Flag(name: .customLong("reconnect")) var reconnect = false
    @Option(name: .customLong("limit")) var limit: Int?
    @Option(name: .customLong("timeout")) var timeout: Double?
    @Flag(name: .customLong("snapshot")) var snapshot = false
    @Flag(name: .customLong("no-ack")) var noAck = false
    @Flag(name: .customLong("no-heartbeat")) var noHeartbeat = false
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "events", helpNames: [])
}

struct LogCommand: NotificationTargetCommand {
    @Option(name: .customLong("level"), completion: .list(["info", "progress", "success", "warning", "error"])) var level: String?
    @Option(name: .customLong("source")) var source: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "log", helpNames: [])
}

struct ListLogCommand: NotificationTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Option(name: .customLong("limit")) var limit: Int?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-log", helpNames: [])
}

struct ClearLogCommand: NotificationTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-log", helpNames: [])
}

struct SetStatusCommand: NotificationTargetCommand {
    @Argument var key: String?
    @Argument var value: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Option(name: .customLong("icon")) var icon: String?
    @Option(name: .customLong("color")) var color: String?
    @Option(name: .customLong("priority")) var priority: Int?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-status", helpNames: [])
}

struct ListStatusCommand: NotificationTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-status", helpNames: [])
}

struct ClearStatusCommand: NotificationTargetCommand {
    @Argument var key: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-status", helpNames: [])
}

struct SetProgressCommand: NotificationTargetCommand {
    @Argument var progress: Double?
    @Option(name: .customLong("label")) var label: String?
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "set-progress", helpNames: [])
}

struct ClearProgressCommand: NotificationTargetCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var window: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear-progress", helpNames: [])
}

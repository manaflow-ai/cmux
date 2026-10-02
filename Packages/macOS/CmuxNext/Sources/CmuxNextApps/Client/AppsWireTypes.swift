public import Foundation

/// An `apps-list` reply.
public nonisolated struct AppsListReply: Sendable, Hashable {
    public var revision: UInt64?
    public var apps: [AppRecord]

    public init(revision: UInt64?, apps: [AppRecord]) {
        self.revision = revision
        self.apps = apps
    }
}

/// The state of an app's host process (`apps-host`).
public nonisolated enum AppHostState: String, Sendable, Hashable {
    case running, stopped, crashed
}

/// One line of an app's log (`apps-logs`, `apps-log`).
public nonisolated struct AppLogLine: Sendable, Hashable, Identifiable {
    public var id: Int
    public var date: Date?
    public var level: String
    public var message: String

    public init(id: Int, date: Date?, level: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

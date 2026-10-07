public import Foundation

/// A folder that agents worked in, from their session files.
public nonisolated struct AgentProject: Sendable, Hashable, Identifiable {
    public var folder: URL
    public var sessions: Int
    public var lastActive: Date
    public var apps: [AgentApp]
    public var id: String { folder.path }

    public init(folder: URL, sessions: Int, lastActive: Date, apps: [AgentApp]) {
        self.folder = folder
        self.sessions = sessions
        self.lastActive = lastActive
        self.apps = apps
    }
}

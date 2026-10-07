public import Foundation

/// One conversation an agent app kept on disk, which cmux can resume by
/// adopting it (`session/new` with `_meta.acpmux.adopt`).
public nonisolated struct AgentChat: Sendable, Hashable, Identifiable {
    /// The app's own session id, the one `adopt` names.
    public var sessionID: String
    public var app: AgentApp
    public var folder: URL
    /// The first prompt's first line, or the app's own summary.
    public var title: String
    /// Prompts the user typed; tool results and injected context don't count.
    public var prompts: Int
    public var lastActive: Date
    public var id: String { "\(app.rawValue):\(sessionID)" }

    public init(sessionID: String, app: AgentApp, folder: URL, title: String, prompts: Int, lastActive: Date) {
        self.sessionID = sessionID
        self.app = app
        self.folder = folder
        self.title = title
        self.prompts = prompts
        self.lastActive = lastActive
    }

    /// The harness name acpmux adopts this app's sessions under.
    public var adoptHarness: String? {
        switch app {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .pi, .opencode: nil
        }
    }
}

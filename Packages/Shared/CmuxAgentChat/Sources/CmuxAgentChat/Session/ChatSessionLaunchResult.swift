import Foundation

/// Result of asking the host to materialize another terminal for a chat
/// session. The provider may not have emitted its child session hook yet, so
/// the terminal and parent ids are returned immediately and the session list
/// remains the eventual source of truth.
public struct ChatSessionLaunchResult: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Equatable, Sendable {
        case fork
        case resume
        case reopen
    }

    public let action: Action
    public let parentSessionID: String
    public let sessionID: String?
    public let workspaceID: String?
    public let terminalID: String?
    public let workingDirectory: String?

    private enum CodingKeys: String, CodingKey {
        case action
        case parentSessionID = "parent_session_id"
        case sessionID = "session_id"
        case workspaceID = "workspace_id"
        case terminalID = "terminal_id"
        case workingDirectory = "cwd"
    }

    public init(
        action: Action,
        parentSessionID: String,
        sessionID: String? = nil,
        workspaceID: String? = nil,
        terminalID: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.action = action
        self.parentSessionID = parentSessionID
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.workingDirectory = workingDirectory
    }
}

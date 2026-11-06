import CmuxAgentChat
import Foundation

enum TerminalCommandSuggestionsError: Error {
    case unavailable, noSession, sessionChanged
}

/// Reads suggestions from original messages, scoped to one terminal and workspace.
struct TerminalCommandSuggestionsLoader: Sendable {
    let sessions: @Sendable (String) async throws -> [ChatSessionDescriptor]
    let history: @Sendable (String, Int?) async throws -> ChatHistoryPage

    func load(workspaceID: String, terminalID: String) async throws -> [TerminalCommandSuggestion] {
        []
    }
}

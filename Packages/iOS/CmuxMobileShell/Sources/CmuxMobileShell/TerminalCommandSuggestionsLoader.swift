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
        try Task.checkCancellation()
        let available = try await sessions(workspaceID).filter {
            $0.agentKind == .claude && $0.kind == .agent && $0.state != .ended
                && Self.matches($0.workspaceID, workspaceID) && Self.matches($0.terminalID, terminalID)
        }
        guard let session = ChatSessionDescriptor.openable(available).first else {
            throw TerminalCommandSuggestionsError.noSession
        }
        var commands: [TerminalCommandSuggestion] = []
        var seen: Set<String> = []
        var cursor: Int?
        for _ in 0..<3 {
            try Task.checkCancellation()
            let page = try await history(session.id, cursor)
            for message in page.messages.sorted(by: { $0.seq > $1.seq }) {
                guard message.role == .agent, case .prose(let prose) = message.kind else { continue }
                for text in BangCommandParser.commands(in: prose.text).reversed() where seen.insert(text).inserted {
                    commands.append(.init(sessionID: session.id, text: text))
                    if commands.count == 50 { return commands }
                }
            }
            guard page.hasMore, let next = page.messages.map(\.seq).min(),
                  next < (cursor ?? .max) else { break }
            cursor = next
        }
        return commands
    }

    static func matches(_ reported: String?, _ expected: String) -> Bool {
        guard let reported else { return false }
        if let lhs = UUID(uuidString: reported), let rhs = UUID(uuidString: expected) { return lhs == rhs }
        return reported == expected
    }
}

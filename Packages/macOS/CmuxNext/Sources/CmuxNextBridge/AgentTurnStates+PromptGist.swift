import Foundation

extension AgentTurnStates {
    /// The line that names a chat in a title or first prompt (red: its first line).
    public nonisolated static func promptGist(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

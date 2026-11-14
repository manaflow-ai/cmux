/// How demanding a Claude session's work is, used as a matrix column.
public enum ClaudeSessionDifficulty: String, CaseIterable, Codable, Sendable {
    case easy, normal, hard
}

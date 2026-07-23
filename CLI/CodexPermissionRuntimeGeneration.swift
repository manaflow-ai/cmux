/// Exact process generation carried by Codex permission evidence.
struct CodexPermissionRuntimeGeneration: Codable, Equatable, Sendable {
    let pid: Int
    let pidStartSeconds: Int64?
    let pidStartMicroseconds: Int64?

    func matches(_ other: Self) -> Bool {
        guard pid == other.pid else { return false }
        if let pidStartSeconds,
           let pidStartMicroseconds,
           let otherSeconds = other.pidStartSeconds,
           let otherMicroseconds = other.pidStartMicroseconds {
            return pidStartSeconds == otherSeconds && pidStartMicroseconds == otherMicroseconds
        }
        return true
    }
}

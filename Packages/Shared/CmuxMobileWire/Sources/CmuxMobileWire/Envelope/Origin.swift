/// The channel a request came from (OWNERSHIP-PRINCIPLES, `action.run` origin).
public enum Origin: String, Hashable, Sendable, Codable {
    case user, cli, mcp, script, remote
}

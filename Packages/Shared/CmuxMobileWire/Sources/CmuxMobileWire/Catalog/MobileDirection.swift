/// Who sends a message: client to server, server to client, or both.
public enum MobileDirection: String, CaseIterable, Hashable, Sendable, Codable {
    case c2s, s2c, both
}

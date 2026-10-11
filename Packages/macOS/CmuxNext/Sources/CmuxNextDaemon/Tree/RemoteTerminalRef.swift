import Foundation

/// A tab in a home-session layout whose terminal runs on another session
/// (`remote-terminal-tabs-v1`, plans/cmux-next/data-model.md 1.2b). The
/// home daemon stores the reference like a frontend browser record and never
/// attaches or spawns; the app attaches to the terminal on its own session.
public struct RemoteTerminalRef: Sendable, Hashable, Codable {
    /// The terminal's session (`registry_id`, lowercase UUID).
    public var sessionID: String
    /// The terminal's host id (32 lowercase hex) on that session.
    public var terminalID: TerminalID
    /// The session's display name when the tab was made (placeholder label).
    public var sessionName: String

    public init(sessionID: String, terminalID: TerminalID, sessionName: String) {
        self.sessionID = sessionID.lowercased()
        self.terminalID = terminalID
        self.sessionName = sessionName
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case terminalID = "terminal_id"
        case sessionName = "session_name"
    }

    /// Session ids compare lowercase (`DaemonIdentity.sessionID`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionID: try c.decode(String.self, forKey: .sessionID), terminalID: try c.decode(TerminalID.self, forKey: .terminalID),
                  sessionName: try c.decodeIfPresent(String.self, forKey: .sessionName) ?? "")
    }
}

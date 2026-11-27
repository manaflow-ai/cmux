import Foundation

/// The own theme of one terminal on any session, kept in the home session's
/// personal state (`personal-terminals-v1`, plans/cmux-next/data-model.md
/// 6). `terminalKey` is the terminal's id on its session (its tab id when it
/// has none).
public struct PersonalTerminal: Sendable, Hashable, Decodable {
    public var sessionID: String
    public var terminalKey: String
    public var theme: String

    public init(sessionID: String, terminalKey: String, theme: String) {
        self.sessionID = sessionID
        self.terminalKey = terminalKey
        self.theme = theme
    }

    enum CodingKeys: String, CodingKey {
        case theme
        case sessionID = "session_id"
        case terminalKey = "terminal_key"
    }
}

extension DaemonConnection {
    /// Whether this daemon stores per-terminal themes.
    public var supportsPersonalTerminals: Bool { identity?.supports(DaemonCapability.personalTerminals.rawValue) == true }

    public func setPersonalTerminal(_ request: SetPersonalTerminalRequest) async throws {
        guard supportsPersonalTerminals else { throw DaemonError.missingCapabilities([DaemonCapability.personalTerminals.rawValue]) }
        _ = try await self.request(request)
    }
}

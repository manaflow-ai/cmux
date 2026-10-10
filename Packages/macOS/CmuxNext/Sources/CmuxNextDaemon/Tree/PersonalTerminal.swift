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

/// Sets or (nil) clears one terminal's own theme.
public struct SetPersonalTerminalRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-personal-terminal"
    public static let requiredCapability: String? = DaemonCapabilities.shared.personalTerminals
    public var sessionID: String
    public var terminalKey: String
    public var theme: String?

    public init(sessionID: String, terminalKey: String, theme: String?) {
        self.sessionID = sessionID
        self.terminalKey = terminalKey
        self.theme = theme
    }

    enum CodingKeys: String, CodingKey {
        case theme
        case sessionID = "session_id"
        case terminalKey = "terminal_key"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(terminalKey, forKey: .terminalKey)
        // JSON null clears.
        try c.encode(theme, forKey: .theme)
    }
}

extension DaemonConnection {
    /// Whether this daemon stores per-terminal themes.
    public var supportsPersonalTerminals: Bool { identity?.supports(DaemonCapabilities.shared.personalTerminals) == true }

    public func setPersonalTerminal(_ request: SetPersonalTerminalRequest) async throws {
        guard supportsPersonalTerminals else { throw DaemonError.missingCapabilities([DaemonCapabilities.shared.personalTerminals]) }
        _ = try await self.request(request)
    }
}

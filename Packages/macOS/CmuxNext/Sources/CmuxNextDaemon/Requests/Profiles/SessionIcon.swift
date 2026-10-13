import Foundation

/// Sets or clears a machine's icon in the home session registry
/// (`session-icon-v1`): the icon the app's sidebar draws for the session
/// `sessionID` (its daemon's `registry_id`). `icon` is always sent; nil
/// sends null, which clears it. The daemon refuses an unknown session and a
/// stored asset its blob store does not hold (`unknown_icon_asset`).
public struct SetSessionIconRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var session: SessionRecord
        public var changed: Bool
    }
    public static let command = "set-session-icon"
    public static let requiredCapability: String? = DaemonCapabilities.shared.sessionIcon
    public var sessionID: String
    /// The icon to set, or nil to clear it.
    public var icon: String?

    public init(sessionID: String, icon: String?) {
        self.sessionID = sessionID
        self.icon = icon
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case icon
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        if let icon { try c.encode(icon, forKey: .icon) } else { try c.encodeNil(forKey: .icon) }
    }
}

extension DaemonConnection {
    /// Sets (a string) or clears (nil) the icon of session `sessionID` in this
    /// home daemon's registry.
    @discardableResult
    public func setSessionIcon(_ sessionID: String, icon: String?) async throws -> SetSessionIconRequest.Response {
        try await request(SetSessionIconRequest(sessionID: sessionID, icon: icon))
    }
}

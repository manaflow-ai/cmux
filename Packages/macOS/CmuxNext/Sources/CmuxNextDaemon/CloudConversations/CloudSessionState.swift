import Foundation

/// `cloud-session-*` data. Never carries the token.
public struct CloudSessionState: Decodable, Sendable, Equatable {
    /// `signed_out`, `active` or `expired`.
    public var state: String
    public var apiBaseURL: String?
    public var expiresAt: UInt64?

    public init(state: String, apiBaseURL: String? = nil, expiresAt: UInt64? = nil) {
        self.state = state
        self.apiBaseURL = apiBaseURL
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case state
        case apiBaseURL = "api_base_url"
        case expiresAt = "expires_at"
    }
}

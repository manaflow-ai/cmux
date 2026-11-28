import Foundation

extension PageCredentialRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var credential: String
        /// Seconds the single-use credential stays valid for its handshake.
        public var expiresIn: UInt64

        enum CodingKeys: String, CodingKey {
            case credential
            case expiresIn = "expires_in"
        }
    }
}

/// `page-credential {page}` (`page-credential-scoped-v1`): a single-use credential bound to one
/// page of the daemon's page-router table, for any trusted local connection. It admits only a
/// WebSocket handshake whose Origin names that page and never carries the person's Cloud lease,
/// so it is narrower than the file token next to the socket.
public struct ScopedPageCredentialRequest: DaemonRequest {
    public typealias Response = PageCredentialRequest.Response

    public static let command = "page-credential"
    public static var requiredCapability: String? { DaemonCapability.scopedPageCredential.rawValue }
    /// The page id (`home-channels`).
    public var page: String

    public init(page: String) {
        self.page = page
    }
}

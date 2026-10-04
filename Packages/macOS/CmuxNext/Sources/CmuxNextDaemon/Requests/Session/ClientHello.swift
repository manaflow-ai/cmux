import Foundation

/// Which kind of local client a connection is (plans/cmux-next/request-origin.md). The daemon
/// fixes it with `client-hello`, the first line or the second right after one `identify`:
/// `main` is the app's own connection; `page_relay` carries React page calls, and the daemon
/// derives origin `page` for every request on it, so a relay request can never run as the user.
public enum DaemonClientRole: String, Sendable, Codable {
    case main
    case pageRelay = "page_relay"
}

/// `client-hello {role}`, sent only to a daemon with `origin-claim-v1` (an older daemon answers
/// unknown command and the connection stays a legacy client). No `install_id` until P8, and
/// never on `page_relay`.
public struct ClientHelloRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var connectionId: String

        enum CodingKeys: String, CodingKey {
            case connectionId = "connection_id"
        }
    }

    public static let command = "client-hello"
    public var role: DaemonClientRole

    public init(role: DaemonClientRole) {
        self.role = role
    }
}

extension DaemonClientRole {
    /// The daemon capability for `client-hello`, the `page_relay` role and origin claims.
    public static let originClaimCapability = "origin-claim-v1"
}

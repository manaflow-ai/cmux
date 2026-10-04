import Foundation

/// Which kind of local client a connection is (plans/cmux-next/request-origin.md). The daemon
/// fixes it with `client-hello`, the first line or the second right after one `identify`:
/// `main` is the app's own connection; `page_relay` carries React page calls, and the daemon
/// derives origin `page` for every request on it, so a relay request can never run as the user.
public enum DaemonClientRole: String, Sendable, Codable {
    case main
    case pageRelay = "page_relay"
}

/// `client-hello` step 1 `{role, install_id?}`. An older daemon answers unknown command and the
/// connection stays a legacy client. `install_id` only on the app's `main` connection (P8,
/// plans/cmux-next/identity.md), never on `page_relay`; with it the daemon returns a nonce and
/// expects `ClientHelloProofRequest` as the very next line.
public struct ClientHelloRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var connectionId: String
        /// Present when the daemon expects step 2 (role main with an install id).
        public var nonce: String?

        enum CodingKeys: String, CodingKey {
            case connectionId = "connection_id"
            case nonce
        }
    }

    public static let command = "client-hello"
    public var role: DaemonClientRole
    public var installID: String?

    public init(role: DaemonClientRole, installID: String? = nil) {
        self.role = role
        self.installID = role == .main ? installID : nil
    }

    enum CodingKeys: String, CodingKey {
        case role
        case installID = "install_id"
    }
}

/// `client-hello` step 2 (P8): the install-key proof over the step 1 nonce. It must be the very
/// next line after step 1.
public struct ClientHelloProofRequest: DaemonRequest {
    public static let command = "client-hello"
    public var installID: String
    public var proof: String

    public init(installID: String, proof: String) {
        self.installID = installID
        self.proof = proof
    }

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case proof
    }

    public struct Response: Decodable, Sendable, Equatable {
        public var verified: Bool
    }
}

extension DaemonClientRole {
    /// The daemon capability for `client-hello`, the `page_relay` role and origin claims.
    public static let originClaimCapability = "origin-claim-v1"
}

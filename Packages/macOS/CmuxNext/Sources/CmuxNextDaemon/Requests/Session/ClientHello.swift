import Foundation

/// `client-hello` step 1 (P8, plans/cmux-next/identity.md): the
/// connection's role, and the install id whose key the app will prove.
/// Sent right after `identify` (at most one line may come before it).
public struct ClientHelloStartRequest: DaemonRequest {
    public static let command = "client-hello"
    public var role: String
    public var installID: String?

    public init(role: String = "main", installID: String?) {
        self.role = role
        self.installID = installID
    }

    enum CodingKeys: String, CodingKey {
        case role
        case installID = "install_id"
    }

    public struct Response: Decodable, Sendable, Equatable {
        public var connectionID: String?
        /// Present when the daemon expects step 2 (role main with an
        /// install id).
        public var nonce: String?

        enum CodingKeys: String, CodingKey {
            case connectionID = "connection_id"
            case nonce
        }
    }
}

/// `client-hello` step 2: the install-key proof over the step 1 nonce. It
/// must be the very next line after step 1.
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

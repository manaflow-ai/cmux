import CmuxIrxTransport
import Foundation

/// The per-user Mac directory served at `/v2/account/*`
/// (`account.directory.result.v1`). It lists the same Stack user's Macs across
/// every team, so a Mac whose other installation selected a different team
/// still finds that installation's current endpoint.
struct AccountMacDirectory: Codable, Equatable, Sendable {
    /// The rule the account service names when it implements cross-team Mac peers.
    static let accountPeerRule = "cmux.mac-account-peer.v1"

    let userID: String
    let revision: Int
    /// Same-user Macs that opted into hosting, excluding the requester.
    let macs: [V2DeviceRecord]
    /// Same-user Macs this host may admit (only when it hosts).
    let inboundMacs: [V2InboundPeerPermission]
    let relayURLs: [String]
    let issuedAt: Int
    let permissionExpiresAt: Int
    let rules: [String]
    /// Present when another page follows at the same revision.
    var nextCursor: String? = nil

    enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case revision, macs, inboundMacs, relayURLs, issuedAt, permissionExpiresAt, rules, nextCursor
    }

    /// Whether the issuing service implements the account peer rule.
    var supportsAccountPeers: Bool { rules.contains(Self.accountPeerRule) }

    /// Joins the pages of one read (same user and revision) into one complete
    /// directory. Its lease is the earliest page's issue time and expiry, so a
    /// slow multi-page read never extends authority. Nil for no pages, an
    /// unfinished read, or pages that disagree.
    static func assembled(_ pages: [AccountMacDirectory]) -> AccountMacDirectory? {
        guard let first = pages.first, pages.last?.nextCursor == nil,
              pages.allSatisfy({ $0.userID == first.userID && $0.revision == first.revision }) else { return nil }
        return AccountMacDirectory(userID: first.userID, revision: first.revision,
            macs: pages.flatMap(\.macs), inboundMacs: pages.flatMap(\.inboundMacs),
            relayURLs: first.relayURLs, issuedAt: pages.map(\.issuedAt).min() ?? first.issuedAt,
            permissionExpiresAt: pages.map(\.permissionExpiresAt).min() ?? first.permissionExpiresAt,
            rules: first.rules, nextCursor: nil)
    }
}

/// One account directory together with the exact team-scoped device that
/// fetched it. A directory is authority only for that device and key
/// generation; a team switch or key replacement makes it inapplicable.
struct AccountMacDirectorySnapshot: Equatable, Sendable {
    let directory: AccountMacDirectory
    let requester: V2DeviceDescriptor

    /// Whether this snapshot was fetched by `descriptor`'s identity and key.
    func belongs(to descriptor: V2DeviceDescriptor) -> Bool {
        requester.identity == descriptor.identity
            && requester.endpointID == descriptor.endpointID
            && requester.identityGeneration == descriptor.identityGeneration
    }

    /// Whether `now` lies inside the directory's issued lease.
    func isFresh(at now: Date) -> Bool {
        let seconds = now.timeIntervalSince1970
        return seconds >= Double(directory.issuedAt) && seconds < Double(directory.permissionExpiresAt)
    }
}

/// Wire frames for the account socket and request route.
enum AccountMacDirectoryWire {
    static let requestPurpose = "cmux-iroh-v2-account-request"

    struct Request: Codable, Equatable, Sendable {
        let schemaId: String
        let requestId: String
        /// Directory paging: continue after this record at `haveRevision`.
        var cursor: String? = nil
        var haveRevision: Int? = nil

        static func publish(_ id: String) -> Request { Request(schemaId: "account.publish.v1", requestId: id) }
        static func directory(_ id: String, cursor: String? = nil, haveRevision: Int? = nil) -> Request {
            Request(schemaId: "account.directory.v1", requestId: id, cursor: cursor, haveRevision: haveRevision)
        }
        static func withdraw(_ id: String) -> Request { Request(schemaId: "account.withdraw.v1", requestId: id) }
    }

    /// Every server frame decodes through this envelope first.
    struct Envelope: Decodable, Sendable {
        let schemaId: String
        let requestId: String?
        let revision: Int?
        let userId: String?
        let code: String?
        let retryable: Bool?
        let retryAfterMs: Int?
    }

    struct DirectoryResult: Decodable, Sendable {
        let schemaId: String
        let requestId: String
        let directory: AccountMacDirectory
    }

    /// The canonical bytes the Worker verifies (`accountRequestSigningInput`).
    /// The purpose differs from team requests so neither proof replays on the other route.
    struct ProofBody<Body: Encodable>: Encodable {
        let purpose = AccountMacDirectoryWire.requestPurpose
        let identity: V2Identity
        let endpointId: String
        let identityGeneration: Int
        let requestId: String
        let issuedAt: Int
        let nonce: String
        let body: Body
    }

    /// The body an HTTP account request signs: the unsigned setup and the request.
    struct HTTPProofBody: Encodable {
        let setup: V2SocketSetup
        let request: Request
    }

    /// Account failures that end the current socket and need new credentials.
    static let credentialFailures: Set<String> = [
        "ticket_expired", "device_revoked", "identity_mismatch", "key_replacement_required",
        "device_not_enrolled", "permission_denied", "unauthorized", "invalid_device_proof",
        "environment_mismatch",
    ]
}

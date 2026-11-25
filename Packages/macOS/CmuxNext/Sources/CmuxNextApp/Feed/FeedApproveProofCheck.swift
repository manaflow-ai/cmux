import CmuxNextFeedClient
import CmuxNextWindowRules
import Foundation

/// The check of a phone's signed approve answer (cx-aocz, the chief-approved
/// App-Attested presence key design). The bridge answers an agent's
/// permission prompt with an allow only when this passes:
///
/// - the proof names the install the owner authenticated as the answerer;
/// - that install has a presence key from an iPhone, attested by App Attest
///   at registration, not revoked, its install active, past its 24 h
///   cooldown (`usable_from`);
/// - the proof is at most 300 s old (and at most 60 s from the future);
/// - the key's P-256 signature covers `cmux-feed-approve-v1`, this backend
///   environment, this user, the phone's install, THIS Mac's install, the
///   item, the sha256 of the text this Mac posted, the decision, the scope and
///   the time.
///
/// Every rule is cmux-feed-approve's (cmux-tui/crates/cmux-feed-approve, with
/// its tests), asked over the app FFI (`feed_approve_*`); this maps the
/// app's values onto the wire. An FFI that does not answer refuses (fail closed).
///
/// A process on this Mac with the user's session can register an install of
/// kind ios, but it cannot make an App Attest attestation for a key, and the
/// key never leaves the phone's Secure Enclave.
///
/// Residual risks: the Mac trusts the backend's `attested` flag (it does not
/// check the App Attest attestation itself); an agent that writes cmux.json
/// can turn `feed.agentPermissionPrompts` on (that sends prompt summaries to
/// the person's own feed; it grants nothing, as an allow still needs the
/// phone's signed proof).
enum FeedApproveProofCheck {
    /// One entry of `user.presence_key.list`, as cmux-feed-approve read it.
    struct Key: Codable, Equatable, Sendable {
        var platform: String
        /// The uncompressed P-256 point, base64url.
        var publicKey: String
        var attested: Bool
        var usableFromMs: Double?
        var revoked: Bool
        var installActive: Bool

        enum CodingKeys: String, CodingKey {
            case platform, attested, revoked
            case publicKey = "public_key", usableFromMs = "usable_from_ms", installActive = "install_active"
        }
    }

    /// Who this Mac is, from its own install token (`iss`, `sub`, `inst`).
    struct Context: Codable, Equatable, Sendable {
        var environment: String
        var user: String
        var macInstall: String

        enum CodingKeys: String, CodingKey {
            case environment, user
            case macInstall = "mac_install"
        }
    }

    enum Failure: String, Error, Equatable, Decodable {
        case noProof
        case otherInstall
        case noKey
        case notPhone
        case notAttested
        case revoked
        case coolingDown
        case stale
        case badKey
        case badSignature
        /// The app FFI did not answer.
        case unavailable
    }

    /// The keys of a `user.presence_key.list` value, by install (malformed entries dropped).
    static func keys(from value: [String: Any]) -> [String: Key] {
        struct Reply: Decodable { var keys: [String: Key] }
        return ask("feed_approve_keys", ["value": value], as: Reply.self)?.keys ?? [:]
    }

    /// This Mac's context from its install token's claims.
    static func context(ofToken token: String) -> Context? {
        struct Reply: Decodable { var context: Context? }
        return ask("feed_approve_context", ["token": token], as: Reply.self)?.context
    }

    /// Checks `decision`'s proof for `item`, answered by `by`.
    static func check(_ decision: FeedApproveDecision, by: String, item: String, shownSHA256: String,
                      context: Context, keys: [String: Key], now: Date) -> Result<Void, Failure> {
        struct Proof: Encodable { var install: String; var timestamp_ms: Int64; var signature: String }
        struct Decision: Encodable { var outcome: String; var scope: String?; var proof: Proof? }
        struct Request: Encodable {
            var decision: Decision
            var by: String
            var item: String
            var shown_sha256: String
            var context: Context
            var keys: [String: Key]
            var now_ms: Double
        }
        struct Reply: Decodable { var failure: Failure? }
        let proof = decision.proof.map { Proof(install: $0.install, timestamp_ms: $0.timestampMs, signature: $0.signature) }
        let request = Request(
            decision: Decision(outcome: decision.outcome.rawValue, scope: decision.scope?.rawValue, proof: proof),
            by: by, item: item, shown_sha256: shownSHA256, context: context, keys: keys,
            now_ms: now.timeIntervalSince1970 * 1000)
        guard let reply = WindowRules().call("feed_approve_check", request, as: Reply.self) else {
            return .failure(.unavailable)
        }
        return reply.failure.map { .failure($0) } ?? .success(())
    }

    /// The sha256 the phone signs for the action this Mac posted. Empty when the FFI does not
    /// answer, which no proof covers.
    static func shownSHA256(action: [String: Any]) -> String {
        struct Reply: Decodable { var sha256: String }
        return ask("feed_approve_shown_sha256", ["action": action], as: Reply.self)?.sha256 ?? ""
    }

    /// A request holding JSON the app received as is (an owner answer, a feed item's action).
    private static func ask<Reply: Decodable>(_ operation: String, _ request: [String: Any], as: Reply.Type) -> Reply? {
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        return WindowRules().call(operation, json: data, as: Reply.self)
    }
}

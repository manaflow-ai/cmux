import CmuxFeedPushCore
import CmuxNextFeed
import CryptoKit
import Foundation

/// The check of a phone's signed approve answer (cx-aocz, the chief-approved
/// App-Attested presence key design). The bridge answers an agent's
/// permission prompt with an allow only when this passes:
///
/// - the proof names the install the owner authenticated as the answerer;
/// - that install has a presence key from an iPhone, attested by App Attest
///   at registration, not revoked, its install active, past its 24 h
///   cooldown (`usable_from`);
/// - the proof is at most `maxAge` old (and not from the future);
/// - the key's P-256 signature covers `cmux-feed-approve-v1`, this backend
///   environment, this user, the phone's install, THIS Mac's install, the
///   item, the sha256 of the text this Mac posted, the decision, the scope and
///   the time.
///
/// A process on this Mac with the user's session can register an install of
/// kind ios, but it cannot make an App Attest attestation for a key, and the
/// key never leaves the phone's Secure Enclave.
enum FeedApproveProofCheck {
    /// One entry of `user.presence_key.list`.
    struct Key: Equatable {
        var platform: String
        var publicKey: Data
        var attested: Bool
        var usableFrom: Date?
        var revoked: Bool
        var installActive: Bool
    }

    /// Who this Mac is, from its own install token (`iss`, `sub`, `inst`).
    struct Context: Equatable {
        var environment: String
        var user: String
        var macInstall: String
    }

    enum Failure: Error, Equatable {
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
    }

    /// The oldest proof accepted, and the clock skew allowed ahead.
    static let maxAge: TimeInterval = 300
    static let maxSkew: TimeInterval = 60

    /// The keys of a `user.presence_key.list` value, by install.
    static func keys(from value: [String: Any]) -> [String: Key] {
        var out: [String: Key] = [:]
        for entry in value["keys"] as? [[String: Any]] ?? [] {
            guard let install = entry["install"] as? String,
                  let jwk = entry["jwk"] as? [String: Any],
                  let x = (jwk["x"] as? String).flatMap(base64URL), x.count == 32,
                  let y = (jwk["y"] as? String).flatMap(base64URL), y.count == 32 else { continue }
            out[install] = Key(
                platform: entry["platform"] as? String ?? "",
                publicKey: Data([0x04]) + x + y,
                attested: entry["attested"] as? Bool ?? false,
                usableFrom: (entry["usable_from"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                revoked: !(entry["revoked_at"] == nil || entry["revoked_at"] is NSNull),
                installActive: entry["install_active"] as? Bool ?? false)
        }
        return out
    }

    /// This Mac's context from its install token's claims.
    static func context(ofToken token: String) -> Context? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let data = base64URL(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = claims["iss"] as? String, issuer.hasPrefix("https://cmux-api/"),
              let user = claims["sub"] as? String, !user.isEmpty,
              let install = claims["inst"] as? String, !install.isEmpty else { return nil }
        let environment = String(issuer.dropFirst("https://cmux-api/".count))
        guard !environment.isEmpty else { return nil }
        return Context(environment: environment, user: user, macInstall: install)
    }

    /// Checks `decision`'s proof for `item`, answered by `by`.
    static func check(_ decision: FeedAnswerValue.Decision, by: String, item: String, shownSHA256: String,
                      context: Context, keys: [String: Key], now: Date) -> Result<Void, Failure> {
        guard let proof = decision.proof else { return .failure(.noProof) }
        guard proof.install == by else { return .failure(.otherInstall) }
        guard let key = keys[proof.install] else { return .failure(.noKey) }
        guard key.platform == "ios" else { return .failure(.notPhone) }
        guard key.attested else { return .failure(.notAttested) }
        guard !key.revoked, key.installActive else { return .failure(.revoked) }
        if let usableFrom = key.usableFrom, usableFrom > now { return .failure(.coolingDown) }
        let signed = Date(timeIntervalSince1970: Double(proof.timestampMs) / 1000)
        guard signed <= now.addingTimeInterval(maxSkew), now.timeIntervalSince(signed) <= maxAge else {
            return .failure(.stale)
        }
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: key.publicKey) else {
            return .failure(.badKey)
        }
        let message = FeedApproveProofMessage(
            environment: context.environment, user: context.user, phoneInstall: proof.install,
            macInstall: context.macInstall, item: item, shownSHA256: shownSHA256,
            decision: decision.outcome.rawValue, scope: decision.scope?.rawValue ?? "once",
            timestampMs: proof.timestampMs)
        guard let raw = base64URL(proof.signature),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              publicKey.isValidSignature(signature, for: message.bytes) else { return .failure(.badSignature) }
        return .success(())
    }

    /// The sha256 the phone signs for the action this Mac posted.
    static func shownSHA256(action: [String: Any]) -> String {
        FeedApproveShownText(action: action).sha256
    }

    static func base64URL(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }
}

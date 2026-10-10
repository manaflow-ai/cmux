#if DEBUG
import CryptoKit
import Foundation

/// A stand-in for the UserDO owner (home-core text-confirm-user.ts) until its
/// routes are live, with the same message format, checks and codes:
/// `ok:false` refusals throw TextConfirmRefusal (nothing changes); a refused
/// proof spends the nonce and answers `lowered: false` with a code.
/// DEBUG only: never in a Release build.
public actor MockTextConfirmOwner: TextConfirmOps {
    public private(set) var level: TextConfirmLevel
    public private(set) var lockedLevel: TextConfirmLevel?
    private let presenceKey: P256.Signing.PublicKey
    private let keyUsableFrom: Date
    private let platformIsIOS: Bool
    private let nonCanonical: Bool
    private let now: @Sendable () -> Date
    private var live: (nonce: String, message: Data, level: TextConfirmLevel, expires: Date)?
    public private(set) var lastAttestHash: Data?

    /// - Parameter nonCanonical: issue JSON in a different key order with
    ///   spaces (tests that the client signs bytes, not re-encoded JSON).
    public init(level: TextConfirmLevel = .strict, lockedLevel: TextConfirmLevel? = nil,
                presenceKey: P256.Signing.PublicKey, keyRegisteredAt: Date, platformIsIOS: Bool = true,
                nonCanonical: Bool = false, now: @escaping @Sendable () -> Date = Date.init) {
        self.level = level
        self.lockedLevel = lockedLevel
        self.presenceKey = presenceKey
        keyUsableFrom = keyRegisteredAt.addingTimeInterval(24 * 3600)
        self.platformIsIOS = platformIsIOS
        self.nonCanonical = nonCanonical
        self.now = now
    }

    public func state() async throws -> TextConfirmState {
        TextConfirmState(level: level, lockedBy: lockedLevel == nil ? nil : "Team policy", lockedLevel: lockedLevel)
    }

    public func setLevel(_ level: TextConfirmLevel, idempotencyKey: String) async throws {
        if self.level.isLowered(to: level) { throw TextConfirmRefusal(code: "text_confirm.proof_required") }
        self.level = level
    }

    public func challenge(for level: TextConfirmLevel, idempotencyKey: String) async throws -> TextConfirmChallenge {
        if let lockedLevel, lockedLevel.isLowered(to: level) { throw TextConfirmRefusal(code: "text_confirm.locked") }
        guard self.level.isLowered(to: level) else { throw TextConfirmRefusal(code: "text_confirm.not_lower") }
        guard now() >= keyUsableFrom else { throw TextConfirmRefusal(code: "text_confirm.key_cooling_down") }
        let nonce = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let expires = now().addingTimeInterval(120)
        let ms = Int(expires.timeIntervalSince1970 * 1000)
        // The owner's proofMessage: a domain line, then canonical JSON (sorted keys).
        let json = nonCanonical
            ? #"{"op": "user.text_confirm.lower", "nonce": "\#(nonce)", "new_level": "\#(level.rawValue)", "user": "user_1", "install": "inst_1", "expires_at": \#(ms)}"#
            : #"{"expires_at":\#(ms),"install":"inst_1","new_level":"\#(level.rawValue)","nonce":"\#(nonce)","op":"user.text_confirm.lower","user":"user_1"}"#
        let message = Data((TextConfirmChallenge.domain + "\n" + json).utf8)
        live = (nonce, message, level, expires)
        return TextConfirmChallenge(nonce: nonce, message: message)
    }

    public func lower(to level: TextConfirmLevel, nonce: String, presenceSignature: String, appAttest: String?,
                      idempotencyKey: String) async throws -> TextConfirmOutcome {
        guard let challenge = live, challenge.nonce == nonce else { throw TextConfirmRefusal(code: "text_confirm.bad_nonce") }
        live = nil  // any attempt spends the nonce
        guard challenge.level == level else { return .refused(code: "text_confirm.proof_mismatch") }
        guard now() < challenge.expires else { return .refused(code: "text_confirm.proof_expired") }
        guard let raw = Data(textConfirmBase64URL: presenceSignature), raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              presenceKey.isValidSignature(signature, for: challenge.message) else {
            return .refused(code: "text_confirm.bad_proof")
        }
        if platformIsIOS {
            // The test attester echoes the client-data hash; the real owner verifies Apple's assertion.
            guard let appAttest, let hash = Data(textConfirmBase64URL: appAttest),
                  hash == Data(SHA256.hash(data: challenge.message)) else { return .refused(code: "text_confirm.bad_proof") }
            lastAttestHash = hash
        }
        self.level = level
        return .lowered
    }
}
#endif

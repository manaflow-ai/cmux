import CryptoKit
import Foundation

/// A stand-in owner until the UserDO routes are live: checks what section 21
/// says the owner checks (one live nonce, expiry, the presence signature over
/// the exact bytes it issued, the 24 h key cooldown, the App Attest client
/// data hash) and commits a refused proof with `lowered: false`.
public actor MockTextConfirmOwner: TextConfirmOps {
    public private(set) var level: TextConfirmLevel
    private let presenceKey: P256.Signing.PublicKey
    private let keyUsableAt: Date
    private let now: @Sendable () -> Date
    private var liveNonce: (nonce: String, message: Data, level: TextConfirmLevel, expires: Date)?
    public private(set) var lastAttestHash: Data?

    public init(level: TextConfirmLevel = .strict, presenceKey: P256.Signing.PublicKey, keyRegisteredAt: Date,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.level = level
        self.presenceKey = presenceKey
        keyUsableAt = keyRegisteredAt.addingTimeInterval(24 * 3600)
        self.now = now
    }

    public func setLevel(_ level: TextConfirmLevel, idempotencyKey: String) async throws {
        guard !self.level.isLowered(to: level) else { throw MockError.proofRequired }
        self.level = level
    }

    public func challenge(for level: TextConfirmLevel, idempotencyKey: String) async throws -> TextConfirmChallenge {
        guard now() >= keyUsableAt else { throw MockError.keyCooldown }
        let nonce = UUID().uuidString.lowercased()
        // Deliberately non-canonical JSON (key order, spacing, an escaped
        // slash): a client that re-encodes the JSON signs different bytes.
        let text = #"{"op":"user.text_confirm.lower", "nonce":"\#(nonce)","new_level":"\#(level.rawValue)","path":"a\/b"}"#
        let message = Data(text.utf8)
        liveNonce = (nonce, message, level, now().addingTimeInterval(120))
        return TextConfirmChallenge(nonce: nonce, message: message)
    }

    public func lower(to level: TextConfirmLevel, nonce: String, presenceSignature: String, appAttest: String?,
                      idempotencyKey: String) async throws -> TextConfirmOutcome {
        // Any attempt spends the nonce.
        guard let live = liveNonce, live.nonce == nonce else { return .refused(code: "text_confirm.nonce") }
        liveNonce = nil
        guard now() <= live.expires else { return .refused(code: "text_confirm.expired") }
        guard live.level == level else { return .refused(code: "text_confirm.level_mismatch") }
        guard let raw = Data(textConfirmBase64URL: presenceSignature), raw.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              presenceKey.isValidSignature(signature, for: live.message) else {
            return .refused(code: "text_confirm.bad_signature")
        }
        if let appAttest { lastAttestHash = Data(textConfirmBase64URL: appAttest) }
        self.level = level
        return .lowered
    }

    public enum MockError: Error { case proofRequired, keyCooldown }
}

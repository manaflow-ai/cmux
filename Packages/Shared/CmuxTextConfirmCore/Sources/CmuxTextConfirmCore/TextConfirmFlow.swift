import CryptoKit
import Foundation

/// The owner's challenge for one lowering (`user.text_confirm.lower.challenge`).
public struct TextConfirmChallenge: Hashable, Sendable {
    public var nonce: String
    /// The exact bytes to sign: base64url-decoded from `message`, never
    /// rebuilt from the JSON of `sign`.
    public var message: Data

    public init(nonce: String, message: Data) {
        self.nonce = nonce
        self.message = message
    }

    /// From the op's `value`: `{sign: {nonce, new_level, ...}, message: <base64url>}`.
    public init?(value: [String: Any], level: TextConfirmLevel) {
        guard let sign = value["sign"] as? [String: Any], let nonce = sign["nonce"] as? String,
              sign["new_level"] as? String == level.rawValue,
              let encoded = value["message"] as? String, let bytes = Data(textConfirmBase64URL: encoded),
              !bytes.isEmpty else { return nil }
        self.init(nonce: nonce, message: bytes)
    }

    /// The domain line of every proof message.
    public static let domain = "cmux-text-confirm-v1"

    /// The presence key signs only a lowering proof for this level and nonce:
    /// `cmux-text-confirm-v1\n{json}` with op user.text_confirm.lower. The
    /// JSON is read to check it, never re-encoded for signing.
    public func isProof(for level: TextConfirmLevel) -> Bool {
        let prefix = Data((Self.domain + "\n").utf8)
        guard message.starts(with: prefix),
              let object = try? JSONSerialization.jsonObject(with: message.dropFirst(prefix.count)) as? [String: Any]
        else { return false }
        return object["op"] as? String == "user.text_confirm.lower"
            && object["new_level"] as? String == level.rawValue
            && object["nonce"] as? String == nonce
    }
}

/// The owner's answer to a lowering attempt.
public enum TextConfirmOutcome: Hashable, Sendable {
    case lowered
    /// The proof was refused (the nonce is spent); `code` says why.
    case refused(code: String)
}

/// An `ok: false` refusal from the owner (nothing changed).
public struct TextConfirmRefusal: Error, Hashable, Sendable {
    public var code: String
    public init(code: String) { self.code = code }
}

/// The owner ops the client uses. Transport failures throw anything else.
public protocol TextConfirmOps: Sendable {
    /// The owner's current level and lock.
    func state() async throws -> TextConfirmState
    func setLevel(_ level: TextConfirmLevel, idempotencyKey: String) async throws
    func challenge(for level: TextConfirmLevel, idempotencyKey: String) async throws -> TextConfirmChallenge
    func lower(to level: TextConfirmLevel, nonce: String, presenceSignature: String, appAttest: String?,
               idempotencyKey: String) async throws -> TextConfirmOutcome
}

/// The presence key: signs only after Face ID, Touch ID or the passcode.
public protocol PresenceSigner: Sendable {
    /// ES256 over `message`: raw r||s (64 bytes) or DER.
    func sign(_ message: Data) async throws -> Data
}

/// App Attest (iOS): an assertion over a client-data hash. Nil on macOS.
public protocol AppAttester: Sendable {
    /// base64url assertion for `clientDataHash`.
    func assertion(clientDataHash: Data) async throws -> String
}

public enum TextConfirmError: Error, Hashable, Sendable {
    /// The challenge is not a lowering proof for the chosen level.
    case badChallenge
    case badSignature
    /// iOS needs an App Attest assertion and none can be made.
    case attestationUnavailable
}

/// Changes the level: a safer level directly, a riskier level with a proof.
public struct TextConfirmFlow: Sendable {
    let ops: any TextConfirmOps
    let signer: any PresenceSigner
    let attester: (any AppAttester)?
    let requiresAttestation: Bool
    let makeKey: @Sendable () -> String

    /// - Parameter requiresAttestation: true on iOS (the owner refuses an iOS
    ///   proof without an App Attest assertion).
    public init(ops: any TextConfirmOps, signer: any PresenceSigner, attester: (any AppAttester)?,
                requiresAttestation: Bool,
                makeKey: @escaping @Sendable () -> String = { "tc-" + UUID().uuidString.lowercased() }) {
        self.ops = ops
        self.signer = signer
        self.attester = attester
        self.requiresAttestation = requiresAttestation
        self.makeKey = makeKey
    }

    /// Returns `.lowered` for a safer level too (applied directly).
    public func change(from current: TextConfirmLevel, to level: TextConfirmLevel) async throws -> TextConfirmOutcome {
        guard current.isLowered(to: level) else {
            try await ops.setLevel(level, idempotencyKey: makeKey())
            return .lowered
        }
        if requiresAttestation, attester == nil { throw TextConfirmError.attestationUnavailable }
        let challenge = try await ops.challenge(for: level, idempotencyKey: makeKey())
        guard challenge.isProof(for: level) else { throw TextConfirmError.badChallenge }
        let signature = try Self.rawSignature(try await signer.sign(challenge.message))
        let attest = try await attester?.assertion(clientDataHash: Data(SHA256.hash(data: challenge.message)))
        // One key for this attempt: a lost answer is retried once with the same key,
        // so the owner applies it at most once and returns the stored result.
        let key = makeKey()
        do {
            return try await ops.lower(to: level, nonce: challenge.nonce, presenceSignature: signature.textConfirmBase64URL,
                                       appAttest: attest, idempotencyKey: key)
        } catch let refusal as TextConfirmRefusal {
            throw refusal
        } catch {
            return try await ops.lower(to: level, nonce: challenge.nonce, presenceSignature: signature.textConfirmBase64URL,
                                       appAttest: attest, idempotencyKey: key)
        }
    }

    /// Raw r||s, exactly 64 bytes (a DER signature is converted).
    public static func rawSignature(_ signature: Data) throws -> Data {
        if signature.count == 64 { return signature }
        guard let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            throw TextConfirmError.badSignature
        }
        return parsed.rawRepresentation
    }
}

extension Data {
    /// base64url without padding.
    public var textConfirmBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init?(textConfirmBase64URL text: String) {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        self.init(base64Encoded: base)
    }
}

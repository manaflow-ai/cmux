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

    /// From the op's `value`: `{sign: {nonce, ...}, message: <base64url>}`.
    public init?(value: [String: Any]) {
        guard let sign = value["sign"] as? [String: Any], let nonce = sign["nonce"] as? String,
              let encoded = value["message"] as? String, let bytes = Data(textConfirmBase64URL: encoded),
              !bytes.isEmpty else { return nil }
        self.init(nonce: nonce, message: bytes)
    }
}

/// The owner's answer to a lowering attempt.
public enum TextConfirmOutcome: Hashable, Sendable {
    case lowered
    /// The proof was refused (the nonce is spent); `code` says why.
    case refused(code: String)
}

/// The three owner ops the client uses.
public protocol TextConfirmOps: Sendable {
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
    case badChallenge
    case badSignature
}

/// Changes the level: a safer level directly, a riskier level with a proof.
public struct TextConfirmFlow: Sendable {
    let ops: any TextConfirmOps
    let signer: any PresenceSigner
    let attester: (any AppAttester)?
    let makeKey: @Sendable () -> String

    public init(ops: any TextConfirmOps, signer: any PresenceSigner, attester: (any AppAttester)?,
                makeKey: @escaping @Sendable () -> String = { "tc-" + UUID().uuidString.lowercased() }) {
        self.ops = ops
        self.signer = signer
        self.attester = attester
        self.makeKey = makeKey
    }

    /// Returns `.lowered` for a safer level too (applied directly).
    public func change(from current: TextConfirmLevel, to level: TextConfirmLevel) async throws -> TextConfirmOutcome {
        guard current.isLowered(to: level) else {
            try await ops.setLevel(level, idempotencyKey: makeKey())
            return .lowered
        }
        let challenge = try await ops.challenge(for: level, idempotencyKey: makeKey())
        let signature = try Self.rawSignature(try await signer.sign(challenge.message))
        let attest = try await attester?.assertion(clientDataHash: Data(SHA256.hash(data: challenge.message)))
        return try await ops.lower(to: level, nonce: challenge.nonce, presenceSignature: signature.textConfirmBase64URL,
                                   appAttest: attest, idempotencyKey: makeKey())
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

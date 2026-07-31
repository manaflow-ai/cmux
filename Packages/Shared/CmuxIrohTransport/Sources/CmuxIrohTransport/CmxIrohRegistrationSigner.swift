import CryptoKit
import Foundation

/// Builds the two-leg registration proof using the Iroh EndpointID key.
public struct CmxIrohRegistrationSigner: Sendable {
    private let secretKey: Data
    private let endpointID: String

    /// Creates a signer and proves the supplied secret derives the endpoint.
    ///
    /// - Throws: ``CmxIrohRegistrationError/endpointIdentityMismatch`` when
    ///   route identity and signing identity differ.
    public init(identity: CmxIrohIdentityMaterial, endpointID: String) throws {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.secretKey.bytes
        )
        let derivedID = Self.hex(privateKey.publicKey.rawRepresentation)
        guard derivedID == endpointID else {
            throw CmxIrohRegistrationError.endpointIdentityMismatch
        }
        secretKey = identity.secretKey.bytes
        self.endpointID = endpointID
    }

    /// Canonically encodes payload bytes and constructs the challenge request.
    public func prepare(
        payload: CmxIrohRegistrationPayload
    ) throws -> CmxIrohPreparedRegistration {
        guard payload.endpointID == endpointID else {
            throw CmxIrohRegistrationError.endpointIdentityMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payloadBytes = try encoder.encode(payload)
        guard !payloadBytes.isEmpty, payloadBytes.count <= 32_768 else {
            throw CmxIrohRegistrationError.payloadTooLarge
        }
        let payloadSHA256 = Self.hex(Data(SHA256.hash(data: payloadBytes)))
        let challenge = CmxIrohChallengeRequest(
            payload: payload,
            payloadSHA256: payloadSHA256
        )
        return CmxIrohPreparedRegistration(
            challengeRequest: challenge,
            encodedPayload: Self.base64URL(payloadBytes),
            payloadSHA256: payloadSHA256,
            endpointID: endpointID
        )
    }

    /// Signs the exact broker challenge and prepared payload hash.
    public func sign(
        prepared: CmxIrohPreparedRegistration,
        challenge: CmxIrohChallengeResponse
    ) throws -> CmxIrohRegisterRequest {
        guard prepared.endpointID == endpointID,
              Self.isBrokerUUID(challenge.challengeID),
              let nonce = Self.decodeBase64URL(challenge.nonce),
              nonce.count == 32 else {
            throw CmxIrohRegistrationError.invalidChallenge
        }
        let challengeID = challenge.challengeID.lowercased()
        let transcript = Data(
            "cmux/iroh/device-registration/v1\n\(challengeID)\n\(challenge.nonce)\n\(prepared.payloadSHA256)".utf8
        )
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secretKey)
        let signature = try privateKey.signature(for: transcript)
        return CmxIrohRegisterRequest(
            challengeID: challengeID,
            nonce: challenge.nonce,
            payload: prepared.encodedPayload,
            signature: Self.base64URL(signature)
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 95
              }) else {
            return nil
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let decoded = Data(base64Encoded: base64),
              base64URL(decoded) == value else {
            return nil
        }
        return decoded
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func isBrokerUUID(_ value: String) -> Bool {
        let bytes = Array(value.lowercased().utf8)
        guard bytes.count == 36,
              bytes[8] == 45,
              bytes[13] == 45,
              bytes[18] == 45,
              bytes[23] == 45,
              (49...56).contains(bytes[14]),
              [56, 57, 97, 98].contains(bytes[19]) else {
            return false
        }
        return bytes.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index)
                ? byte == 45
                : (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

import CMUXMobileCore
import CryptoKit
import Foundation
@testable import CmuxIrohTransport

struct HostPolicyCacheTestFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let binding: CmxIrohBrokerBindingMetadata
    let pairingEnabled: Bool
    let capabilities: [String]
    let keySet: CmxIrohGrantVerificationKeySet
    let alternateKeySet: CmxIrohGrantVerificationKeySet
    let lanRendezvous: CmxIrohLANRendezvous

    private let signingKey: Curve25519.Signing.PrivateKey

    init(
        binding: CmxIrohBrokerBindingMetadata? = nil,
        pairingEnabled: Bool = true,
        capabilities: [String] = ["control", "multistream-v1"]
    ) throws {
        signingKey = Curve25519.Signing.PrivateKey()
        let alternateKey = Curve25519.Signing.PrivateKey()
        keySet = Self.keySet(id: "current", key: signingKey)
        alternateKeySet = Self.keySet(id: "current", key: alternateKey)
        self.binding = try binding ?? CmxIrohBrokerBindingMetadata(
            bindingID: "123e4567-e89b-42d3-a456-426614174010",
            deviceID: "123e4567-e89b-42d3-a456-426614174011",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174012",
            tag: "cmux-ios-v0",
            platform: .mac,
            endpointID: CmxIrohPeerIdentity(
                endpointID: String(repeating: "ab", count: 32)
            ),
            identityGeneration: 4
        )
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
        lanRendezvous = try JSONDecoder().decode(
            CmxIrohLANRendezvous.self,
            from: JSONSerialization.data(withJSONObject: [
                "generation": 3,
                "key": Data(repeating: 9, count: 32).base64URL,
            ])
        )
    }

    func expectation(
        accountID: String = "account-a",
        appInstanceID: String? = nil,
        endpointID: CmxIrohPeerIdentity? = nil,
        identityGeneration: Int? = nil,
        pairingEnabled: Bool? = nil,
        capabilities: [String]? = nil
    ) throws -> CmxIrohHostPolicyExpectation {
        try CmxIrohHostPolicyExpectation(
            accountID: accountID,
            deviceID: binding.deviceID,
            appInstanceID: appInstanceID ?? binding.appInstanceID,
            tag: binding.tag,
            endpointID: endpointID ?? binding.endpointID,
            identityGeneration: identityGeneration ?? binding.identityGeneration,
            pairingEnabled: pairingEnabled ?? self.pairingEnabled,
            capabilities: capabilities ?? self.capabilities
        )
    }

    func policy(
        keySet: CmxIrohGrantVerificationKeySet? = nil,
        responseKeySet: CmxIrohGrantVerificationKeySet? = nil,
        expiresAt: Date? = nil
    ) throws -> CmxIrohCachedHostPolicy {
        let selectedKeySet = keySet ?? self.keySet
        let responseKeys = responseKeySet ?? selectedKeySet
        return try CmxIrohCachedHostPolicy(
            binding: binding,
            pairingEnabled: pairingEnabled,
            capabilities: capabilities,
            grantVerificationKeys: selectedKeySet,
            endpointAttestation: attestation(
                expiresAt: expiresAt ?? now.addingTimeInterval(3_600),
                responseKeySet: responseKeys
            ),
            lanRendezvous: lanRendezvous
        )
    }

    func policySignedByOriginalKey(
        publishedKeySet: CmxIrohGrantVerificationKeySet
    ) throws -> CmxIrohCachedHostPolicy {
        try policy(keySet: publishedKeySet, responseKeySet: publishedKeySet)
    }

    private func attestation(
        expiresAt: Date,
        responseKeySet: CmxIrohGrantVerificationKeySet
    ) throws -> CmxIrohEndpointAttestationResponse {
        let issuedAt = Int64(now.timeIntervalSince1970) - 10
        let expiry = Int64(expiresAt.timeIntervalSince1970)
        let claims: [String: Any] = [
            "version": 1,
            "jti": "123e4567-e89b-42d3-a456-426614174099",
            "sub": Data(repeating: 7, count: 32).base64URL,
            "bindingId": binding.bindingID,
            "deviceId": binding.deviceID,
            "endpointId": binding.endpointID.endpointID,
            "identityGeneration": binding.identityGeneration,
            "platform": CmxIrohPlatform.mac.rawValue,
            "iat": issuedAt,
            "nbf": issuedAt,
            "exp": expiry,
            "alpn": "cmux/mobile/1",
            "scope": "cmux.offline-pair.same-account",
        ]
        let header = try JSONSerialization.data(
            withJSONObject: [
                "alg": "EdDSA",
                "typ": "cmux-endpoint-attestation-v1+jwt",
                "kid": "current",
            ],
            options: [.sortedKeys]
        ).base64URL
        let payload = try JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys]
        ).base64URL
        let signingInput = "\(header).\(payload)"
        let signature = try signingKey.signature(
            for: Data(signingInput.utf8)
        ).base64URL
        return CmxIrohEndpointAttestationResponse(
            attestationVersion: 1,
            attestation: "\(signingInput).\(signature)",
            expiresAt: Self.iso8601(Date(timeIntervalSince1970: TimeInterval(expiry))),
            grantVerificationKeys: responseKeySet
        )
    }

    private static func keySet(
        id: String,
        key: Curve25519.Signing.PrivateKey
    ) -> CmxIrohGrantVerificationKeySet {
        let prefix = Data([
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
            0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
        ])
        return CmxIrohGrantVerificationKeySet(
            version: 1,
            currentKeyID: id,
            keys: [
                CmxIrohGrantVerificationKey(
                    kid: id,
                    alg: "EdDSA",
                    spkiDerBase64: (prefix + key.publicKey.rawRepresentation)
                        .base64EncodedString()
                ),
            ]
        )
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

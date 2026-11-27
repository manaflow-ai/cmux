import CryptoKit
public import Foundation

/// Verifies root-pinned compact JWS relay policies with strict claim shape.
public struct CmxIrohRelayPolicyVerifier: Sendable {
    /// Maximum relays accepted in one catalog, including all managed providers.
    public static let maximumRelayCount = 16

    private struct Header: Decodable {
        let alg: String
        let typ: String
        let kid: String
    }

    private struct RelayClaims: Decodable {
        let id: String
        let provider: String
        let region: String
        let url: String
    }

    private struct PolicyClaims: Decodable {
        let version: Int
        let policyID: String
        let sequence: Int64
        let issuedAt: Int64
        let notBefore: Int64
        let expiresAt: Int64
        let audience: String
        let relayProtocol: String
        let relays: [RelayClaims]

        private enum CodingKeys: String, CodingKey {
            case version
            case policyID = "jti"
            case sequence
            case issuedAt = "iat"
            case notBefore = "nbf"
            case expiresAt = "exp"
            case audience = "aud"
            case relayProtocol = "relay_protocol"
            case relays
        }
    }

    private static let tokenType = "cmux-relay-policy-v1+jwt"
    private static let audience = "cmux-iroh-relay-policy"
    private static let relayProtocol = "iroh-relay-v1"
    private static let maximumLifetime: Int64 = 7 * 24 * 60 * 60

    /// Creates a stateless relay-policy verifier.
    public init() {}

    /// Authenticates and validates one signed relay policy.
    ///
    /// - Parameters:
    ///   - token: A compact EdDSA JWS issued by cmux's relay-policy authority.
    ///   - trustRoot: App-pinned public keys, never supplied by the policy response.
    ///   - now: Verification time, injected for deterministic tests.
    /// - Returns: A verified managed-relay policy.
    /// - Throws: ``CmxIrohRelayPolicyError`` for signature, shape, or time failures.
    public func verify(
        _ token: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date
    ) throws -> CmxIrohManagedRelayPolicy {
        guard (5 ... 64 * 1_024).contains(token.utf8.count) else {
            throw CmxIrohRelayPolicyError.invalidToken
        }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = Self.decodeBase64URL(String(segments[0])),
              let payload = Self.decodeBase64URL(String(segments[1])),
              let signature = Self.decodeBase64URL(String(segments[2])),
              signature.count == 64 else {
            throw CmxIrohRelayPolicyError.invalidToken
        }
        try Self.requireExactKeys(headerData, expected: ["alg", "typ", "kid"])
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: headerData)
        } catch {
            throw CmxIrohRelayPolicyError.invalidHeader
        }
        guard header.alg == "EdDSA",
              header.typ == Self.tokenType,
              CmxIrohRelayPolicyVerificationKey.isSafeKeyID(header.kid) else {
            throw CmxIrohRelayPolicyError.invalidHeader
        }
        guard let verificationKey = trustRoot.key(id: header.kid) else {
            throw CmxIrohRelayPolicyError.unknownKeyID
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: verificationKey.rawPublicKey
            )
        } catch {
            throw CmxIrohRelayPolicyError.invalidTrustRoot
        }
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw CmxIrohRelayPolicyError.invalidSignature
        }

        try Self.requireExactPolicyShape(payload)
        let claims: PolicyClaims
        do {
            claims = try JSONDecoder().decode(PolicyClaims.self, from: payload)
        } catch {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        let policy = CmxIrohManagedRelayPolicy(
            version: claims.version,
            policyID: claims.policyID,
            sequence: claims.sequence,
            issuedAt: claims.issuedAt,
            notBefore: claims.notBefore,
            expiresAt: claims.expiresAt,
            audience: claims.audience,
            relayProtocol: claims.relayProtocol,
            relays: claims.relays.map {
                CmxIrohManagedRelayDescriptor(
                    id: $0.id,
                    provider: $0.provider,
                    region: $0.region,
                    url: $0.url
                )
            }
        )
        try Self.validate(policy, now: now)
        return policy
    }

    private static func validate(
        _ policy: CmxIrohManagedRelayPolicy,
        now: Date
    ) throws {
        let time = now.timeIntervalSince1970
        guard time.isFinite,
              time >= TimeInterval(Int64.min),
              time <= TimeInterval(Int64.max) else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        let nowSeconds = Int64(time.rounded(.down))
        let futureTolerance = nowSeconds.addingReportingOverflow(30)
        let lifetime = policy.expiresAt.subtractingReportingOverflow(policy.issuedAt)
        let notBeforeFloor = policy.issuedAt.subtractingReportingOverflow(30)
        guard !futureTolerance.overflow,
              !lifetime.overflow,
              !notBeforeFloor.overflow,
              policy.version == 1,
              UUID(uuidString: policy.policyID)?.uuidString.lowercased() == policy.policyID,
              policy.sequence > 0,
              policy.audience == audience,
              policy.notBefore >= notBeforeFloor.partialValue,
              policy.notBefore <= futureTolerance.partialValue,
              policy.expiresAt > policy.notBefore,
              lifetime.partialValue > 0,
              lifetime.partialValue <= maximumLifetime,
              policy.issuedAt <= futureTolerance.partialValue,
              (1 ... maximumRelayCount).contains(policy.relays.count),
              Set(policy.relays.map(\.id)).count == policy.relays.count,
              Set(policy.relays.map(\.url)).count == policy.relays.count,
              policy.relays.allSatisfy(validRelay) else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        guard policy.relayProtocol == relayProtocol else {
            throw CmxIrohRelayPolicyError.unsupportedRelayProtocol
        }
        // Distributed clients and the signing service do not share a clock.
        // Apply the same bounded skew allowance already required for `iat` so
        // a freshly issued policy cannot fail merely because the server is a
        // few seconds ahead, while policies beyond the 30-second window still
        // fail closed as invalid claims above.
        guard policy.notBefore <= futureTolerance.partialValue else {
            throw CmxIrohRelayPolicyError.notYetValid
        }
        guard policy.expiresAt > nowSeconds else {
            throw CmxIrohRelayPolicyError.expired
        }
    }

    private static func validRelay(_ relay: CmxIrohManagedRelayDescriptor) -> Bool {
        isSafeIdentifier(relay.id)
            && isSafeLabel(relay.provider)
            && isSafeLabel(relay.region)
            && isCanonicalManagedRelayURL(relay.url)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }

    private static func isSafeLabel(_ value: String) -> Bool {
        guard (1 ... 80).contains(value.utf8.count),
              value.utf8.first != 32,
              value.utf8.last != 32 else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [32, 45, 46, 95].contains(byte)
        }
    }

    private static func isCanonicalManagedRelayURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              host == host.lowercased(),
              !host.isEmpty,
              components.port.map({ (1 ... 65_535).contains($0) }) ?? true,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/" else {
            return false
        }
        return components.string == value
    }

    private static func requireExactPolicyShape(_ data: Data) throws {
        let expected: Set<String> = [
            "version", "jti", "sequence", "iat", "nbf", "exp", "aud",
            "relay_protocol", "relays",
        ]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expected,
              let relays = object["relays"] as? [[String: Any]],
              relays.allSatisfy({ Set($0.keys) == ["id", "provider", "region", "url"] }) else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
    }

    private static func requireExactKeys(_ data: Data, expected: Set<String>) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expected else {
            throw CmxIrohRelayPolicyError.invalidHeader
        }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
                      || (65 ... 90).contains(byte)
                      || (97 ... 122).contains(byte)
                      || byte == 45 || byte == 95
              }) else {
            return nil
        }
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard), base64URL(data) == value else {
            return nil
        }
        return data
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import CryptoKit
import Foundation

@testable import CmuxPeerTransport

/// Signs test relay policies with a locally generated Ed25519 key using the
/// exact production wire format (EdDSA compact JWS, strict claim shape).
struct PeerRelayPolicySigner {
    let privateKey: Curve25519.Signing.PrivateKey
    let keyID: String
    let now = Date(timeIntervalSince1970: 1_782_000_000)
    let relayURLs = [
        "https://usc1.relay.cmux.dev/",
        "https://euw4.relay.cmux.dev/",
    ]
    let relayIDs = ["cmux-us", "cmux-eu"]
    let regions = ["us-central1", "europe-west4"]

    var nowSeconds: Int64 { Int64(now.timeIntervalSince1970) }

    init(keyID: String = "policy-2026-1") {
        privateKey = Curve25519.Signing.PrivateKey()
        self.keyID = keyID
    }

    func trustRoot() throws -> PeerRelayPolicyTrustRoot {
        try PeerRelayPolicyTrustRoot(keys: [
            PeerRelayPolicyVerificationKey(
                keyID: keyID,
                rawPublicKeyBase64: privateKey.publicKey.rawRepresentation
                    .base64EncodedString()
            ),
        ])
    }

    func verifiedPolicy(sequence: Int64 = 7) throws -> PeerRelayPolicy {
        try PeerRelayPolicyVerifier().verify(
            token(sequence: sequence),
            trustRoot: trustRoot(),
            now: now
        )
    }

    func token(
        sequence: Int64,
        issuedAt: Int64? = nil,
        notBefore: Int64? = nil,
        expiresAt: Int64? = nil,
        relayProtocol: String = "iroh-relay-v1",
        headerKeyID: String? = nil,
        relayURLs: [String]? = nil,
        regions: [String]? = nil,
        relaysOverride: [[String: Any]]? = nil,
        extraClaims: [String: Any] = [:],
        signingKey: Curve25519.Signing.PrivateKey? = nil
    ) throws -> String {
        let header = try JSONSerialization.data(
            withJSONObject: [
                "alg": "EdDSA",
                "typ": "cmux-relay-policy-v1+jwt",
                "kid": headerKeyID ?? keyID,
            ],
            options: [.sortedKeys]
        )
        let payload = try payload(
            sequence: sequence,
            relayURLs: relayURLs,
            regions: regions,
            relaysOverride: relaysOverride,
            issuedAt: issuedAt,
            notBefore: notBefore,
            expiresAt: expiresAt,
            relayProtocol: relayProtocol,
            extraClaims: extraClaims
        )
        let signingInput = "\(Self.base64URL(header)).\(Self.base64URL(payload))"
        let key = signingKey ?? privateKey
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(Self.base64URL(signature))"
    }

    func payload(
        sequence: Int64,
        relayURLs: [String]? = nil,
        regions: [String]? = nil,
        relaysOverride: [[String: Any]]? = nil,
        issuedAt: Int64? = nil,
        notBefore: Int64? = nil,
        expiresAt: Int64? = nil,
        relayProtocol: String = "iroh-relay-v1",
        extraClaims: [String: Any] = [:]
    ) throws -> Data {
        let relays: [[String: Any]]
        if let relaysOverride {
            relays = relaysOverride
        } else {
            let urls = relayURLs ?? self.relayURLs
            let regions = regions ?? self.regions
            relays = urls.enumerated().map { index, url in
                [
                    "id": relayIDs.indices.contains(index)
                        ? relayIDs[index] : "relay-\(index)",
                    "provider": "cmux",
                    "region": regions.indices.contains(index)
                        ? regions[index] : "region-\(index)",
                    "url": url,
                ]
            }
        }
        var object: [String: Any] = [
            "version": 1,
            "jti": "123e4567-e89b-42d3-a456-426614174000",
            "sequence": sequence,
            "iat": issuedAt ?? nowSeconds,
            "nbf": notBefore ?? issuedAt ?? nowSeconds,
            "exp": expiresAt ?? nowSeconds + 3_600,
            "aud": "cmux-iroh-relay-policy",
            "relay_protocol": relayProtocol,
            "relays": relays,
        ]
        for (key, value) in extraClaims {
            object[key] = value
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    /// A broker-minted 300-second credential response covering `urls`.
    func mintedResponse(
        urls: [String]? = nil,
        token: String = "aaa.bbb.ccc",
        expiresIn: TimeInterval = 300,
        refreshIn: TimeInterval = 240
    ) -> PeerRelayTokenResponse {
        PeerRelayTokenResponse(
            credentials: (urls ?? relayURLs).map { url in
                PeerRelayCredential(
                    relayURL: url,
                    token: token,
                    expiresAt: Self.iso(now.addingTimeInterval(expiresIn)),
                    refreshAfter: Self.iso(now.addingTimeInterval(refreshIn))
                )
            }
        )
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// In-memory relay-policy store with fault injection for cache tests.
actor InMemoryRelayPolicyStore: PeerRelayPolicyStoring {
    enum StoreError: Error {
        case unavailable
    }

    private var data: Data?
    private var failReads = false
    private(set) var writeCount = 0

    func readRecord() async throws -> Data? {
        guard !failReads else { throw StoreError.unavailable }
        return data
    }

    func writeRecord(_ data: Data) async throws {
        self.data = data
        writeCount += 1
    }

    func removeAll() async throws {
        data = nil
    }

    func replaceRecord(_ data: Data?) {
        self.data = data
    }

    func setFailReads(_ value: Bool) {
        failReads = value
    }

    func currentData() -> Data? {
        data
    }
}

import CMUXMobileCore
import CryptoKit
import Foundation
@testable import CmuxPeerTransport

/// Protocol-stub HTTP transport that records every request and replays a
/// scripted response sequence.
actor RecordingBrokerTransport: PeerBrokerHTTPTransporting {
    struct Response: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]

        static func json(
            status: Int,
            body: String,
            headers: [String: String] = [:]
        ) -> Self {
            Self(status: status, body: Data(body.utf8), headers: headers)
        }
    }

    private var pending: [Response]
    private var captured: [URLRequest] = []
    private let failure: (any Error)?

    init(responses: [Response] = [], failure: (any Error)? = nil) {
        pending = responses
        self.failure = failure
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        captured.append(request)
        if let failure { throw failure }
        let response = pending.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
                .merging(response.headers) { _, new in new }
        )!
        return (response.body, http)
    }

    func requests() -> [URLRequest] { captured }
}

/// Scripted credential source: `capture` pops the next entry (repeating the
/// last one when exhausted) and `forceRefresh` counts invocations.
actor ScriptedTokenSource {
    private var pairs: [PeerBrokerCredentials?]
    private var last: PeerBrokerCredentials?
    private(set) var captureCount = 0
    private(set) var forceRefreshCount = 0

    init(_ pairs: [PeerBrokerCredentials?]) {
        self.pairs = pairs
        last = pairs.last ?? nil
    }

    func capture() -> PeerBrokerCredentials? {
        captureCount += 1
        guard !pairs.isEmpty else { return last }
        let next = pairs.removeFirst()
        last = next
        return next
    }

    func forceRefresh() {
        forceRefreshCount += 1
    }

    nonisolated var provider: PeerBrokerTokenProvider {
        PeerBrokerTokenProvider(
            capture: { await self.capture() },
            forceRefresh: { await self.forceRefresh() }
        )
    }
}

enum BrokerFixtures {
    /// Ed25519 seed 0,1,...,31; the EndpointID below is its public key, the
    /// same value iroh derives, pinning CryptoKit/iroh derivation equality.
    static let secretBytes = Data((0 ..< 32).map(UInt8.init))
    static let endpointID =
        "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
    static let bindingID = "123e4567-e89b-42d3-a456-426614174010"
    static let relayURLs = [
        "https://euc1-1.relay.lawrence.cmux.iroh.link/",
        "https://use1-1.relay.lawrence.cmux.iroh.link/",
    ]

    static var staleFreshCredentials: (PeerBrokerCredentials, PeerBrokerCredentials) {
        (
            PeerBrokerCredentials(accessToken: "stale-access", refreshToken: "stale-refresh"),
            PeerBrokerCredentials(accessToken: "fresh-access", refreshToken: "fresh-refresh")
        )
    }

    static func identity(generation: Int = 1) throws -> PeerEndpointIdentity {
        try PeerEndpointIdentity(
            secretKey: PeerSecretKey(bytes: secretBytes),
            generation: generation
        )
    }

    static func signer() throws -> PeerRegistrationSigner {
        try PeerRegistrationSigner(identity: identity(), endpointID: endpointID)
    }

    static func registrationPayload() throws -> PeerRegistrationPayload {
        try PeerRegistrationPayload(
            deviceID: "123e4567-e89b-42d3-a456-426614174001",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "stable",
            platform: .ios,
            endpointID: endpointID,
            identityGeneration: 1,
            pairingEnabled: false,
            capabilities: ["control"],
            pathHints: [],
            now: Date(timeIntervalSince1970: 1_782_000_000)
        )
    }

    static func makeClient(
        transport: any PeerBrokerHTTPTransporting,
        tokenProvider: PeerBrokerTokenProvider? = nil,
        clientNamespace: String = "dev.cmux.app.internal",
        bindingAuthorization: PeerBindingRequestAuthorization? = nil,
        discoveryScope: PeerDiscoveryScope? = nil
    ) throws -> PeerTrustBrokerClient {
        try PeerTrustBrokerClient(
            baseURL: URL(string: "https://cmux.example")!,
            tokenProvider: tokenProvider ?? PeerBrokerTokenProvider(
                capture: {
                    PeerBrokerCredentials(accessToken: "access", refreshToken: "refresh")
                }
            ),
            clientNamespace: clientNamespace,
            bindingAuthorization: bindingAuthorization,
            discoveryScope: discoveryScope,
            transport: transport
        )
    }

    static func iosDiscoveryScope() throws -> PeerDiscoveryScope {
        try PeerDiscoveryScope(
            deviceID: "123e4567-e89b-42d3-a456-426614174001",
            appInstanceID: "123e4567-e89b-42d3-a456-426614174002",
            tag: "stable",
            platform: .ios,
            peerPlatform: .mac,
            peerTags: ["nightly", "default"],
            peerPairingEnabled: true
        )
    }

    static let challengeBody =
        #"{"challenge_id":"123e4567-e89b-42d3-a456-426614174000","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-07-10T01:00:00.000Z"}"#

    static let registrationResponse = """
    {
      "binding": {
        "binding_id": "\(bindingID)",
        "device_id": "123e4567-e89b-42d3-a456-426614174001",
        "app_instance_id": "123e4567-e89b-42d3-a456-426614174002",
        "tag": "stable",
        "platform": "ios",
        "display_name": null,
        "endpoint_id": "\(endpointID)",
        "identity_generation": 1,
        "pairing_enabled": false,
        "capabilities": ["control"],
        "path_hints": [],
        "last_seen_at": "2026-07-10T00:00:00.000Z"
      },
      "relay": {
        "status": "issued",
        "token": "abc234",
        "expires_at": "2026-07-11T00:00:00.000Z",
        "refresh_after": "2026-07-10T12:00:00.000Z",
        "relay_fleet": [
          "\(relayURLs[0])",
          "\(relayURLs[1])"
        ]
      }
    }
    """

    static let discoveryResponse = """
    {
      "route_contract_version": 1,
      "bindings": [{
        "binding_id": "\(bindingID)",
        "device_id": "123e4567-e89b-42d3-a456-426614174001",
        "app_instance_id": "123e4567-e89b-42d3-a456-426614174002",
        "tag": "stable",
        "platform": "mac",
        "display_name": "Mac",
        "endpoint_id": "\(endpointID)",
        "identity_generation": 1,
        "pairing_enabled": true,
        "capabilities": ["control"],
        "path_hints": [{
          "kind": "relay_url",
          "value": "\(relayURLs[0])",
          "source": "native",
          "privacy_scope": "public_internet",
          "observed_at": "2026-07-10T00:00:00.000Z",
          "expires_at": "2026-07-10T01:00:00.000Z"
        }],
        "last_seen_at": "2026-07-10T00:00:00.000Z"
      }],
      "relay_fleet": ["\(relayURLs[0])"],
      "lan_rendezvous": {
        "generation": 1,
        "key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      },
      "grant_verification_keys": {
        "version": 1,
        "current_kid": "current",
        "keys": []
      }
    }
    """

    static func discoveryResponse(
        bindingRange: Range<Int>,
        nextCursor: String?,
        revision: Int? = nil
    ) throws -> String {
        var object = try JSONSerialization.jsonObject(
            with: Data(discoveryResponse.utf8)
        ) as! [String: Any]
        let template = (object["bindings"] as! [[String: Any]]).first!
        object["bindings"] = bindingRange.map { index -> [String: Any] in
            var binding = template
            binding["binding_id"] = String(format: "123e4567-e89b-42d3-a456-%012d", index)
            binding["app_instance_id"] = String(
                format: "223e4567-e89b-42d3-a456-%012d",
                index
            )
            binding["endpoint_id"] = String(format: "%064llx", UInt64(index))
            return binding
        }
        object["next_cursor"] = nextCursor ?? NSNull()
        if let revision {
            object["revision"] = revision
        }
        return jsonString(object)
    }

    static func jsonObject(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    static func jsonString(_ object: [String: Any]) -> String {
        String(
            data: try! JSONSerialization.data(withJSONObject: object),
            encoding: .utf8
        )!
    }

    static func bodyObject(_ request: URLRequest) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func makeRelayJWT(endpointID: String) -> String {
        [
            base64URL(Data(#"{"alg":"EdDSA","typ":"JWT"}"#.utf8)),
            base64URL(Data(
                #"{"iss":"cmux","aud":"cmux-relay","exp":1782000300,"endpoint_id":"\#(endpointID)"}"#.utf8
            )),
            "signature",
        ].joined(separator: ".")
    }
}

/// In-memory three-state secure store used by identity and cache tests.
actor MemoryBlobStore: PeerSecureBlobStoring {
    private var records: [String: Data] = [:]
    private var unavailableStatus: Int32?
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var deleteAllCount = 0

    func read(account: String) -> PeerSecureReadResult {
        readCount += 1
        if let unavailableStatus {
            return .unavailable(status: unavailableStatus)
        }
        guard let data = records[account] else { return .absent }
        return .found(data)
    }

    func write(_ data: Data, account: String) {
        writeCount += 1
        records[account] = data
    }

    func delete(account: String) {
        records.removeValue(forKey: account)
    }

    func deleteAll() {
        deleteAllCount += 1
        records.removeAll()
    }

    func setUnavailable(status: Int32?) {
        unavailableStatus = status
    }

    func contents() -> [String: Data] { records }

    func install(_ data: Data, account: String) {
        records[account] = data
    }
}

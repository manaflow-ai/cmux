@testable import CmuxDeviceHub
import Foundation
import Testing

@Suite struct DeviceHubClientTests {
    /// Checks a recorded request's account and device headers against `identity`.
    func expectSigned(_ request: RecordedRequest, by identity: DeviceIdentity, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(request.header("Authorization") == "Bearer hub-session", sourceLocation: sourceLocation)
        #expect(request.header("X-Device-Id") == identity.id, sourceLocation: sourceLocation)
        #expect(request.header("X-Device-Ts") == "1800000000", sourceLocation: sourceLocation)
        let canonical = DeviceRequestSigner.canonical(method: request.method, pathAndQuery: request.pathAndQuery,
                                                      timestamp: 1_800_000_000, body: request.body)
        #expect(DeviceIdentity.verify(signature: request.header("X-Device-Sig") ?? "", of: Data(canonical.utf8),
                                      signingKey: identity.signingKey), sourceLocation: sourceLocation)
    }

    @Test func theAccountExchangeSendsTheStackTokenUnsigned() async throws {
        let hub = StubHub.routes(["GET /v1/me": (200, #"{"userId":"user-1","plan":"paid"}"#)])
        let client = makeClient(hub)
        let me = try await client.me()
        #expect(me == HubMe(userId: "user-1", plan: .paid))
        let exchange = try #require(hub.requests.first)
        #expect(exchange.method == "POST" && exchange.url.path == "/v1/auth/stack")
        #expect(exchange.jsonBody?["token"] as? String == "stack-token")
        #expect(exchange.header("X-Device-Sig") == nil)
        let session = try await client.accountSession()
        #expect(session == DeviceHubAccountSession(token: "hub-session", userId: "user-1", expiresAt: Date(timeIntervalSince1970: 1_800_003_600)))
        // One exchange serves later calls.
        _ = try await client.me()
        #expect(hub.requests.filter { $0.url.path == "/v1/auth/stack" }.count == 1)
    }

    @Test func registrationSendsThisDevicesKeysSignedByThem() async throws {
        let identity = DeviceIdentity.software()
        let hub = StubHub.routes(["POST /v1/devices": (200, #"{"device":{"id":"6f1c2a4e-0d3b-4c5a-9e7f-112233445566","name":"Studio","platform":"macos","macScreenShared":0,"online":true}}"#)])
        let device = try await makeClient(hub, identity: identity).registerDevice(name: "Studio", platform: .macos)
        #expect(device.id == identity.id && device.name == "Studio" && device.online && !device.macScreenShared)
        let request = try #require(hub.requests.last)
        expectSigned(request, by: identity)
        #expect(request.header("Content-Type") == "application/json")
        let body = try #require(request.jsonBody)
        #expect(body["id"] as? String == identity.id)
        #expect(body["name"] as? String == "Studio")
        #expect(body["platform"] as? String == "macos")
        #expect(body["signingKey"] as? String == identity.signingKey)
        #expect(body["agreementKey"] as? String == identity.agreementKey)
    }

    /// Sign-out ends this device's sessions on the hub (reason `signed_out`) before the account session goes.
    @Test func signOutPostsThisDevicesSignOut() async throws {
        let identity = DeviceIdentity.software()
        let hub = StubHub.routes(["POST /v1/devices/\(identity.id)/sign-out": (200, "{}")])
        let client = makeClient(hub, identity: identity)
        try await client.signOutDevice()
        let calls = hub.requests.filter { $0.url.path != "/v1/auth/stack" }
        #expect(calls.map { "\($0.method) \($0.pathAndQuery)" } == ["POST /v1/devices/\(identity.id)/sign-out"])
        for call in calls { expectSigned(call, by: identity) }
    }

    @Test func everyEndpointHasItsMethodPathAndBody() async throws {
        let identity = DeviceIdentity.software()
        let device = #"{"device":{"id":"d2","name":"Phone"}}"#
        let session = #"{"session":{"id":"s1","state":"pending","scope":"view"}}"#
        let hub = StubHub.routes([
            "GET /v1/devices": (200, #"{"devices":[{"id":"d2","name":"Phone","platform":"ios","online":false}]}"#),
            "PATCH /v1/devices/d2": (200, device),
            "DELETE /v1/devices/d2": (200, "{}"),
            "PUT /v1/devices/\(identity.id)/mac-screen": (200, #"{"device":{"id":"\#(identity.id)","name":"Mac","macScreenShared":true}}"#),
            "GET /v1/permissions": (200, #"{"permissions":[{"viewerId":"d2","scope":"view"}]}"#),
            "PUT /v1/permissions/h1/d2": (200, #"{"permission":{"hostId":"h1","viewerId":"d2","scope":"full"}}"#),
            "POST /v1/sessions": (200, session),
            "POST /v1/sessions/s1/decision": (200, #"{"session":{"id":"s1","state":"approved","scope":"full"}}"#),
            "POST /v1/sessions/s1/end": (200, "{}"),
            "POST /v1/sessions/s1/ice": (200, #"{"ice":[{"urls":"turn:cf.example:3478","username":"u","credential":"c"}]}"#),
            "GET /v1/relays": (200, #"{"relays":[{"id":"r1","name":"Home","urls":["turn:h:3478"],"authMode":"shared_secret","sealed":{"x":"blob"},"enabled":1,"priority":2}]}"#),
            "PUT /v1/relays/r1": (200, #"{"relay":{"id":"r1","name":"Home","urls":["turn:h:3478"],"authMode":"static","enabled":true,"priority":0}}"#),
            "DELETE /v1/relays/r1": (200, "{}"),
            "GET /v1/audit": (200, #"{"entries":[{"id":"a1","ts":1800000000000,"event":"requested","viewerId":"d2","hostId":"h1","duration_s":12}]}"#),
        ])
        let client = makeClient(hub, identity: identity)

        #expect(try await client.devices() == [HubDevice(id: "d2", name: "Phone", platform: .ios)])
        _ = try await client.renameDevice("d2", name: "Phone 2")
        try await client.removeDevice("d2")
        #expect(try await client.setMacScreenShared(true).macScreenShared)
        #expect(try await client.permissions(host: "h1") == [HubPermission(viewerId: "d2", scope: .view)])
        #expect(try await client.setPermission(host: "h1", viewer: "d2", scope: .full).scope == .full)
        #expect(try await client.requestSession(host: "h1", scope: .view) == HubSession(id: "s1", state: .pending, scope: .view))
        #expect(try await client.decide(session: "s1", decision: .always, scope: .full).state == .approved)
        try await client.endSession("s1", reason: "user")
        #expect(try await client.sessionICE("s1") == [DeviceHubICEServer(urls: ["turn:cf.example:3478"], username: "u", credential: "c")])
        let relays = try await client.relays()
        #expect(relays.first?.sealedForThisDevice == "blob" && relays.first?.enabled == true && relays.first?.authMode == .sharedSecret)
        _ = try await client.putRelay(RelayUpdate(id: "r1", name: "Home", urls: ["turn:h:3478"], authMode: .static,
                                                  sealed: ["d2": "b2"], enabled: true, priority: 0))
        try await client.deleteRelay("r1")
        let audit = try await client.audit(limit: 5, before: Date(timeIntervalSince1970: 1_799_999_999), device: "h1")
        #expect(audit.first?.ts == Date(timeIntervalSince1970: 1_800_000_000) && audit.first?.durationS == 12)

        let calls = hub.requests.filter { $0.url.path != "/v1/auth/stack" }
        #expect(calls.map { "\($0.method) \($0.pathAndQuery)" } == [
            "GET /v1/devices", "PATCH /v1/devices/d2", "DELETE /v1/devices/d2", "PUT /v1/devices/\(identity.id)/mac-screen",
            "GET /v1/permissions?host=h1", "PUT /v1/permissions/h1/d2", "POST /v1/sessions", "POST /v1/sessions/s1/decision",
            "POST /v1/sessions/s1/end", "POST /v1/sessions/s1/ice", "GET /v1/relays", "PUT /v1/relays/r1", "DELETE /v1/relays/r1",
            "GET /v1/audit?limit=5&before=1799999999000&device=h1",
        ])
        for call in calls { expectSigned(call, by: identity) }
        func body(_ index: Int) -> [String: Any] { calls[index].jsonBody ?? [:] }
        #expect(body(1)["name"] as? String == "Phone 2")
        #expect(body(3)["shared"] as? Bool == true)
        #expect(body(5)["scope"] as? String == "full")
        #expect(body(6)["hostId"] as? String == "h1" && body(6)["scope"] as? String == "view")
        #expect(body(7)["decision"] as? String == "always" && body(7)["scope"] as? String == "full")
        #expect(body(8)["reason"] as? String == "user")
        #expect(calls[0].body == nil || calls[0].body?.isEmpty == true)
        let relay = body(11)
        #expect(relay["id"] == nil, "the id is in the path")
        #expect(relay["name"] as? String == "Home" && relay["authMode"] as? String == "static")
        #expect(relay["sealed"] as? [String: String] == ["d2": "b2"] && relay["enabled"] as? Bool == true && relay["priority"] as? Int == 0)
    }

    @Test func protocolErrorsDecodeToTheirCodes() async throws {
        let hub = StubHub.routes(["POST /v1/sessions": (403, #"{"error":{"code":"scope_exceeds_permission","message":"view only"}}"#),
                                  "GET /v1/devices": (409, #"{"error":{"code":"host_offline","message":"offline"}}"#),
                                  "GET /v1/relays": (500, "oops")])
        let client = makeClient(hub)
        await #expect(throws: DeviceHubError.server(status: 403, code: .scopeExceedsPermission, message: "view only")) {
            try await client.requestSession(host: "h", scope: .full)
        }
        await #expect(throws: DeviceHubError.server(status: 409, code: .hostOffline, message: "offline")) { try await client.devices() }
        await #expect(throws: DeviceHubError.http(status: 500)) { try await client.relays() }
        #expect(DeviceHubError.Code("rate_limited") == .rateLimited)
        #expect(DeviceHubError.Code("new_code") == .other("new_code"))
    }

    @Test func anAccountRefusalExchangesAgainOnce() async throws {
        let refused = Mutexed(true)
        let hub = StubHub { request in
            if request.url.path == "/v1/auth/stack" {
                return (200, #"{"session":"hub-session","userId":"user-1","expiresAt":1800003600000}"#)
            }
            if refused.take() { return (401, #"{"error":{"code":"unauthorized","message":"session expired"}}"#) }
            return (200, #"{"devices":[]}"#)
        }
        let client = makeClient(hub)
        #expect(try await client.devices().isEmpty)
        #expect(hub.requests.filter { $0.url.path == "/v1/auth/stack" }.count == 2)
    }

    @Test func aBadSignatureIsNotRetried() async throws {
        let hub = StubHub.routes(["GET /v1/devices": (401, #"{"error":{"code":"bad_signature","message":"no"}}"#)])
        await #expect(throws: DeviceHubError.server(status: 401, code: .badSignature, message: "no")) { try await makeClient(hub).devices() }
        #expect(hub.requests.filter { $0.url.path == "/v1/devices" }.count == 1)
    }

    @Test func noStackTokenIsNotSignedIn() async {
        let hub = StubHub.routes([:])
        let client = DeviceHubClient(baseURL: hub.baseURL, identity: .software(),
                                     tokens: DeviceHubAccountToken { throw URLError(.userAuthenticationRequired) },
                                     session: StubHub.session, now: fixedNow)
        await #expect(throws: DeviceHubError.notSignedIn) { try await client.devices() }
    }

    @Test func theUserSocketRequestIsSignedForItsPath() async throws {
        let identity = DeviceIdentity.software()
        let hub = StubHub.routes([:])
        let handshake = try await makeClient(hub, identity: identity).userSocketHandshake()
        let request = handshake.request
        #expect(request.url?.absoluteString == "wss://\(hub.host)/v1/user/ws")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hub-session")
        #expect(request.value(forHTTPHeaderField: "X-Device-Id") == identity.id)
        let canonical = DeviceRequestSigner.canonical(method: "GET", pathAndQuery: "/v1/user/ws", timestamp: 1_800_000_000, body: nil)
        #expect(DeviceIdentity.verify(signature: request.value(forHTTPHeaderField: "X-Device-Sig") ?? "", of: Data(canonical.utf8),
                                      signingKey: identity.signingKey))
    }

    @Test func aBaseURLWithAPathKeepsIt() {
        let client = DeviceHubClient(baseURL: URL(string: "https://dev.example:8787/hub/")!, identity: .software(),
                                     tokens: DeviceHubAccountToken { "" })
        #expect(client.url("/v1/me").absoluteString == "https://dev.example:8787/hub/v1/me")
        #expect(client.segment("a/b c") == "a%2Fb%20c")
    }
}

/// A flag that reads true once.
final class Mutexed: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func take() -> Bool { lock.withLock { defer { value = false }; return value } }
}

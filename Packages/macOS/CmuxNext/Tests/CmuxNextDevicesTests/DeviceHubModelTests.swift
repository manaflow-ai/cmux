@testable import CmuxNextDevices
import Foundation
import Testing

@MainActor @Suite struct DeviceHubModelTests {
    let me = DeviceIdentity.software()
    let phone = DeviceIdentity.software("a1b2c3d4-0000-4000-8000-000000000001")


    func makeHub(_ stub: StubHub, secrets: any RelaySecretStore = MemoryRelaySecretStore()) -> DeviceHub {
        DeviceHub(client: makeClient(stub, identity: me), secrets: secrets, deviceName: "Studio", now: fixedNow)
    }

    @Test func aDevicesPushRefetchesTheDevices() async {
        let me = self.me, phone = self.phone
        let listed = Locked([(me, "Studio")])
        let stub = StubHub { request in
            if request.url.path == "/v1/auth/stack" { return (200, #"{"session":"hub-session","userId":"u","expiresAt":1800003600000}"#) }
            return (200, devicesJSON(listed.value))
        }
        let hub = makeHub(stub)
        await hub.refreshDevices()
        #expect(hub.devices.map(\.name) == ["Studio"])
        #expect(hub.thisDevice?.id == me.id)
        listed.set([(me, "Studio"), (phone, "Phone")])
        await hub.handle(.push(.devicesChanged))
        #expect(Set(hub.devices.map(\.name)) == ["Studio", "Phone"])
        #expect(hub.otherDevices.map(\.id) == [phone.id])
    }

    @Test func aPermissionsPushRefetchesThatHost() async {
        let stub = StubHub.routes(["GET /v1/permissions": (200, #"{"permissions":[{"viewerId":"v1","scope":"full"}]}"#)])
        let hub = makeHub(stub)
        await hub.handle(.push(.permissionsChanged(hostID: "h1")))
        #expect(hub.scope(host: "h1", viewer: "v1") == .full)
        #expect(hub.scope(host: "h1", viewer: "v2") == .ask)
        #expect(stub.requests.last?.pathAndQuery == "/v1/permissions?host=h1")
    }

    @Test func sessionPushesTrackRequestsAndTickets() async {
        let hub = makeHub(StubHub.routes([:]))
        var seen: [DeviceHubPush] = []
        hub.onSessionPush = { seen.append($0) }
        let request = SessionRequest(id: "s1", viewerId: phone.id, viewerName: "Phone", scope: .full)
        await hub.handle(.push(.sessionRequest(request)))
        await hub.handle(.push(.sessionRequest(request)))
        #expect(hub.pendingRequests == [request])
        let ticket = SessionTicket(sessionId: "s1", ticket: "t", signalURL: URL(string: "wss://h/v1/sessions/s1/ws")!, ice: [],
                                   peer: .init(id: phone.id, name: "Phone", signingKey: phone.signingKey), role: .host, scope: .full)
        await hub.handle(.push(.sessionTicket(ticket)))
        #expect(hub.pendingRequests.isEmpty)
        #expect(hub.tickets["s1"] == ticket)
        await hub.handle(.push(.sessionRevoked(sessionID: "s1", reason: "permission_changed")))
        #expect(hub.tickets.isEmpty)
        #expect(seen.count == 4)
        #expect(seen.last == .sessionRevoked(sessionID: "s1", reason: "permission_changed"))
    }

    /// The socket coming back is a change: History reads its log again (a relaunched host's new entries).
    @Test func reconnectingCountsAsAChange() async {
        let hub = makeHub(StubHub.routes([:]))
        await hub.handle(.state(.connected))
        #expect(hub.pushCount == 1)
    }

    /// A relay deleted elsewhere: its opened secret leaves this Mac's keychain too.
    @Test func deletedRelaysLoseTheirSecrets() async {
        let secrets = MemoryRelaySecretStore()
        secrets.save(.sharedSecret("old"), relayID: "gone")
        secrets.save(.sharedSecret("kept"), relayID: "r1")
        let stub = StubHub.routes(["GET /v1/relays": (200, #"{"relays":[{"id":"r1","name":"Home","urls":["turn:h:3478"],"authMode":"shared_secret","sealed":{},"enabled":true,"priority":0}]}"#)])
        let hub = makeHub(stub, secrets: secrets)
        await hub.handle(.push(.relaysChanged))
        #expect(secrets.secret(relayID: "gone") == nil)
        #expect(secrets.secret(relayID: "r1") == .sharedSecret("kept"))
        #expect(secrets.relayIDs() == ["r1"])
    }

    /// Removing another device never changes this device's identity or empties its History:
    /// only a removal of THIS device makes a new identity.
    @Test func removingAnotherDeviceKeepsIdentityAndHistory() async throws {
        let me = self.me, phone = self.phone
        let listed = Locked([(me, "Studio"), (phone, "Phone")])
        let stub = StubHub { request in
            switch (request.method, request.url.path) {
            case (_, "/v1/auth/stack"): return (200, #"{"session":"hub-session","userId":"u","expiresAt":1800003600000}"#)
            case ("GET", "/v1/devices"): return (200, devicesJSON(listed.value))
            case ("DELETE", _): return (200, "{}")
            case ("GET", "/v1/audit"):
                return (200, #"{"entries":[{"id":"a3","ts":1800000002000,"event":"device_removed","deviceId":"p","deviceName":"Phone"},{"id":"a2","ts":1800000001000,"event":"ended","viewerId":"p","hostId":"m"},{"id":"a1","ts":1800000000000,"event":"started","viewerId":"p","hostId":"m"}]}"#)
            default: return (200, "{}")
            }
        }
        let hub = DeviceHub(client: makeClient(stub, identity: me), secrets: MemoryRelaySecretStore(), deviceName: "Studio",
                            renewIdentity: { DeviceIdentity.software("ffffffff-0000-4000-8000-000000000009") }, now: fixedNow)
        await hub.refreshDevices()
        await hub.refreshAudit()
        #expect(hub.audit.count == 3)
        try await hub.removeDevice(phone.id)
        listed.set([(me, "Studio")])
        await hub.handle(.push(.devicesChanged))
        await hub.handle(.push(.sessionRevoked(sessionID: "s1", reason: "device_removed:viewer")))
        await hub.refreshAudit()
        #expect(hub.identity.id == me.id)
        #expect(hub.audit.count == 3)
        #expect(stub.requests.last { $0.url.path == "/v1/audit" }?.pathAndQuery.contains("device=\(me.id)") == true)
        #expect(hub.status != .failed("this device was removed"))
    }

    /// Entries name their devices as they were (`viewerName`, `hostName`, `deviceName`), even removed ones.
    @Test func auditEntriesReadTheirDevicesNames() throws {
        let data = Data(#"{"id":"a","event":"ended","viewerId":"v","hostId":"h","viewerName":"Laptop","hostName":"Studio","deviceName":null}"#.utf8)
        let entry = try JSONDecoder().decode(AuditEntry.self, from: data)
        #expect(entry.viewerName == "Laptop" && entry.hostName == "Studio" && entry.deviceName == nil)
    }

    /// Audit entries carry `deviceId` for device_added and device_removed.
    @Test func auditEntriesReadTheirDevice() throws {
        let data = Data(#"{"id":"a","ts":1800000000000,"event":"device_added","deviceId":"d1"}"#.utf8)
        let entry = try JSONDecoder().decode(AuditEntry.self, from: data)
        #expect(entry.deviceId == "d1" && entry.event == "device_added")
    }

    /// Settings > Devices reads the audit log again after every push but `pong`.
    @Test func pushesAreCountedButPongs() async {
        let hub = makeHub(StubHub.routes([:]))
        #expect(hub.pushCount == 0)
        await hub.handle(.push(.pong))
        #expect(hub.pushCount == 0)
        await hub.handle(.push(.sessionDenied(sessionID: "s1")))
        await hub.handle(.push(.unknown("team.changed")))
        #expect(hub.pushCount == 2)
        hub.stop()
        #expect(hub.pushCount == 0)
    }

    @Test func aRelaysPushOpensThisDevicesSecret() async throws {
        let blob = try RelaySealing.seal(.sharedSecret("turn-secret"), relayID: "r1", to: me.agreementKey)
        let stub = StubHub.routes(["GET /v1/relays": (200, #"{"relays":[{"id":"r1","name":"Home","urls":["turns:home:5349"],"authMode":"shared_secret","sealed":{"\#(me.id)":"\#(blob)"},"enabled":true,"priority":0},{"id":"r2","name":"Off","urls":["turn:x"],"authMode":"static","enabled":false,"priority":0}]}"#)])
        let secrets = MemoryRelaySecretStore()
        let hub = makeHub(stub, secrets: secrets)
        await hub.handle(.push(.relaysChanged))
        #expect(hub.relays.map(\.id) == ["r1", "r2"])
        #expect(secrets.secret(relayID: "r1") == .sharedSecret("turn-secret"))
        let ticket = SessionTicket(sessionId: "s", ticket: "t", signalURL: URL(string: "wss://h")!,
                                   ice: [DeviceHubICEServer(urls: ["turn:cf:3478"], username: "cf", credential: "c")],
                                   peer: .init(id: "p", name: "P", signingKey: ""), role: .viewer, scope: .view)
        let ice = hub.iceServers(for: ticket)
        #expect(ice.map(\.urls) == [["turn:cf:3478"], ["turns:home:5349"]])
        // The TURN-safe label of the device name.
        #expect(ice.last?.username == "1800021600:studio")
    }

    @Test func savingARelaySealsItForEveryDevice() async throws {
        let me = self.me, phone = self.phone
        let stub = StubHub { request in
            switch (request.method, request.url.path) {
            case (_, "/v1/auth/stack"): return (200, #"{"session":"hub-session","userId":"u","expiresAt":1800003600000}"#)
            case ("GET", "/v1/devices"): return (200, devicesJSON([(me, "Studio"), (phone, "Phone")]))
            case ("PUT", _): return (200, #"{"relay":{"id":"r9","name":"Home","urls":["turn:h"],"authMode":"static","enabled":true,"priority":1}}"#)
            default: return (200, #"{"relays":[]}"#)
            }
        }
        let secrets = MemoryRelaySecretStore()
        let hub = makeHub(stub, secrets: secrets)
        try await hub.saveRelay(id: "r9", name: "Home", urls: ["turn:h"], secret: .static(username: "u", password: "p"), priority: 1)
        let put = try #require(stub.requests.first { $0.method == "PUT" })
        #expect(put.url.path == "/v1/relays/r9")
        let sealed = try #require(put.jsonBody?["sealed"] as? [String: String])
        #expect(Set(sealed.keys) == [me.id, phone.id])
        #expect(try RelaySealing(identity: phone).open(sealed[phone.id]!, relayID: "r9") == .static(username: "u", password: "p"))
        #expect(secrets.secret(relayID: "r9") == .static(username: "u", password: "p"))
    }

    @Test func startRegistersThisDeviceThenStopForgetsEverything() async {
        let stub = StubHub.routes(["POST /v1/devices": (200, #"{"device":{"id":"x","name":"Studio"}}"#)])
        let hub = DeviceHub(client: makeClient(stub, identity: me),
                            socket: DeviceHubSocket(connector: FakeConnector([])), secrets: MemoryRelaySecretStore(),
                            deviceName: "Studio", now: fixedNow)
        await hub.start()
        #expect(hub.status == .ready)
        let registration = stub.requests.first { $0.url.path == "/v1/devices" }
        #expect(registration?.jsonBody?["name"] as? String == "Studio")
        await hub.handle(.push(.sessionRequest(SessionRequest(id: "s", viewerId: "v", viewerName: "V", scope: .view))))
        hub.stop()
        #expect(hub.status == .idle && hub.pendingRequests.isEmpty && hub.devices.isEmpty)
    }

    @Test func aRemovedDeviceRegistersAgainAsANewDevice() async {
        let me = self.me, fresh = DeviceIdentity.software("b0b0b0b0-0000-4000-8000-000000000002")
        let stub = StubHub { request in
            if request.url.path == "/v1/auth/stack" { return (200, #"{"session":"hub-session","userId":"u","expiresAt":1800003600000}"#) }
            if request.header("X-Device-Id") == me.id { return (403, #"{"error":{"code":"device_removed","message":"removed"}}"#) }
            return (200, #"{"device":{"id":"\#(fresh.id)","name":"Studio"}}"#)
        }
        let hub = DeviceHub(client: makeClient(stub, identity: me), socket: DeviceHubSocket(connector: FakeConnector([])),
                            secrets: MemoryRelaySecretStore(), deviceName: "Studio", renewIdentity: { fresh }, now: fixedNow)
        await hub.start()
        #expect(hub.status == .ready)
        #expect(hub.identity.id == fresh.id)
        let registrations = stub.requests.filter { $0.url.path == "/v1/devices" }
        #expect(registrations.map { $0.header("X-Device-Id") } == [me.id, fresh.id])
        #expect(registrations.last?.jsonBody?["signingKey"] as? String == fresh.signingKey)
        hub.stop()
    }

    @Test func aFailedRegistrationIsReported() async {
        let stub = StubHub.routes(["POST /v1/devices": (429, #"{"error":{"code":"rate_limited","message":"slow down"}}"#)])
        let hub = makeHub(stub)
        await hub.start()
        #expect(hub.lastError == .server(status: 429, code: .rateLimited, message: "slow down"))
        guard case .failed = hub.status else {
            Issue.record("expected failed, got \(hub.status)")
            return
        }
    }
}

/// `{devices:[…]}` for these identities, online, with their agreement keys.
func devicesJSON(_ rows: [(DeviceIdentity, String)]) -> String {
    let items = rows.map { identity, name in
        #"{"id":"\#(identity.id)","name":"\#(name)","agreementKey":"\#(identity.agreementKey)","online":true}"#
    }
    return #"{"devices":[\#(items.joined(separator: ","))]}"#
}

/// A value shared with a stub handler.
// generic-class-allow: CmuxNextDevicesTests builds with daemonSwiftSettings (no MainActor default isolation), so this class and its implicit deinit are nonisolated
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

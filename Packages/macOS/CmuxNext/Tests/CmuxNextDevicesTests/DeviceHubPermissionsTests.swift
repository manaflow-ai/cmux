@testable import CmuxNextDevices
import Foundation
import Testing

/// What this device may do on other hosts comes from the hub every time it
/// reconnects or refreshes: no permission read before a gap outlives it.
@MainActor @Suite struct DeviceHubPermissionsTests {
    let me = DeviceIdentity.software()
    let host = DeviceIdentity.software("c0c0c0c0-0000-4000-8000-000000000003")
    let viewer = DeviceIdentity.software("d0d0d0d0-0000-4000-8000-000000000004")

    /// A hub whose `GET /v1/permissions?host=` answers from `scopes` (host id to viewer id to scope).
    private func stub(scopes: Locked<[String: [String: String]]>, devices: Locked<String>) -> StubHub {
        StubHub { request in
            switch (request.method, request.url.path) {
            case (_, "/v1/auth/stack"): return (200, #"{"session":"hub-session","userId":"u","expiresAt":1800003600000}"#)
            case ("GET", "/v1/devices"): return (200, devices.value)
            case ("GET", "/v1/permissions"):
                let host = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "host" }?.value ?? ""
                let rows = (scopes.value[host] ?? [:]).sorted { $0.key < $1.key }.map { #"{"viewerId":"\#($0.key)","scope":"\#($0.value)"}"# }
                return (200, #"{"permissions":[\#(rows.joined(separator: ","))]}"#)
            case ("GET", "/v1/me"): return (200, #"{"userId":"u","plan":"free","device":{"id":"x","name":"Studio"}}"#)
            case ("GET", "/v1/relays"): return (200, #"{"relays":[]}"#)
            case ("DELETE", _): return (200, "{}")
            default: return (200, "{}")
            }
        }
    }

    /// `{devices:[…]}` with this Mac and a host that shares Mac Screen.
    private func devicesWithSharedHost() -> String {
        let rows = [(me, "Studio", false), (host, "Host", true)].map { identity, name, shared in
            #"{"id":"\#(identity.id)","name":"\#(name)","agreementKey":"\#(identity.agreementKey)","online":true,"macScreenShared":\#(shared)}"#
        }
        return #"{"devices":[\#(rows.joined(separator: ","))]}"#
    }

    /// H7 D11: the viewer's hub link dropped, the host lowered this Mac from
    /// Full Control to View Only meanwhile (its push was lost), the link came
    /// back. The access shown must be the hub's current one.
    @Test func reconnectingRereadsThisDevicesAccessToEveryHost() async {
        let scopes = Locked<[String: [String: String]]>([host.id: [me.id: "full"]])
        let hub = DeviceHub(client: makeClient(stub(scopes: scopes, devices: Locked(devicesWithSharedHost())), identity: me),
                            secrets: MemoryRelaySecretStore(), deviceName: "Studio", now: fixedNow)
        await hub.refreshDevices()
        await hub.refreshPermissions(host: host.id)
        #expect(hub.scope(host: host.id, viewer: me.id) == .full)
        // The link is down; the host changes the permission; its push never arrives.
        await hub.handle(.state(.reconnecting("network lost")))
        scopes.set([host.id: [me.id: "view"]])
        await hub.handle(.state(.connected))
        #expect(hub.scope(host: host.id, viewer: me.id) == .view)
    }

    /// Settings › Devices › Refresh reads every host's permissions again too.
    @Test func refreshAllRereadsThisDevicesAccessToEveryHost() async {
        let scopes = Locked<[String: [String: String]]>([host.id: [me.id: "full"]])
        let hub = DeviceHub(client: makeClient(stub(scopes: scopes, devices: Locked(devicesWithSharedHost())), identity: me),
                            secrets: MemoryRelaySecretStore(), deviceName: "Studio", now: fixedNow)
        await hub.refreshDevices()
        await hub.refreshPermissions(host: host.id)
        scopes.set([host.id: [me.id: "view"]])
        await hub.refreshAll()
        #expect(hub.scope(host: host.id, viewer: me.id) == .view)
    }

    /// H7 D2: removing a device leaves no permission that names it, as host or as viewer.
    @Test func removingADeviceForgetsItsPermissions() async throws {
        let scopes = Locked<[String: [String: String]]>([me.id: [viewer.id: "full", host.id: "view"], viewer.id: [me.id: "view"]])
        let hub = DeviceHub(client: makeClient(stub(scopes: scopes, devices: Locked(devicesWithSharedHost())), identity: me),
                            secrets: MemoryRelaySecretStore(), deviceName: "Studio", now: fixedNow)
        await hub.refreshPermissions(host: me.id)
        await hub.refreshPermissions(host: viewer.id)
        #expect(hub.scope(host: me.id, viewer: viewer.id) == .full)
        try await hub.removeDevice(viewer.id)
        #expect(hub.permissions[viewer.id] == nil)
        #expect(hub.permissions.values.joined().allSatisfy { $0.viewerId != viewer.id })
        #expect(hub.scope(host: me.id, viewer: host.id) == .view)
    }
}

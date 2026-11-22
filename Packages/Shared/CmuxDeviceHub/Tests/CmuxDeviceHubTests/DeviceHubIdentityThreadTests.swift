@testable import CmuxDeviceHub
import Foundation
import Testing

/// PR #22788 review: the device identity (file Keychain reads, Secure Enclave
/// key generation) took 8-20 s on some Macs in H7, so it must never load or
/// renew on the main thread.
@MainActor @Suite struct DeviceHubIdentityThreadTests {
    @Test func theAppIdentityLoadsOffTheMainThread() async throws {
        let want = DeviceIdentity.software("c0c0c0c0-0000-4000-8000-000000000003")
        let onMain = Locked<Bool?>(nil)
        let identity = try await DeviceHub.loadIdentity {
            onMain.set(Thread.isMainThread)
            return want
        }
        #expect(identity.id == want.id)
        #expect(onMain.value == false)
    }

    @Test func aRenewedIdentityIsMadeOffTheMainThread() async {
        let me = DeviceIdentity.software(), fresh = DeviceIdentity.software("b0b0b0b0-0000-4000-8000-000000000004")
        let onMain = Locked<Bool?>(nil)
        let stub = StubHub { request in
            if request.url.path == "/v1/auth/stack" { return (200, #"{"session":"hub-session","userId":"u","expiresAt":1800003600000}"#) }
            if request.header("X-Device-Id") == me.id { return (403, #"{"error":{"code":"device_removed","message":"removed"}}"#) }
            return (200, #"{"device":{"id":"\#(fresh.id)","name":"Studio"}}"#)
        }
        let hub = DeviceHub(client: makeClient(stub, identity: me), socket: DeviceHubSocket(connector: FakeConnector([])),
                            secrets: MemoryRelaySecretStore(), deviceName: "Studio",
                            renewIdentity: { onMain.set(Thread.isMainThread); return fresh }, now: fixedNow)
        await hub.start()
        #expect(hub.identity.id == fresh.id)
        #expect(onMain.value == false)
        hub.stop()
    }
}

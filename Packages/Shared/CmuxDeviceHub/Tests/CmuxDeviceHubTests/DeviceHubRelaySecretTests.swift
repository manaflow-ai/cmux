@testable import CmuxDeviceHub
import Foundation
import Testing

/// A relay secret store that records each call and whether it ran on the
/// main thread. The app's store is the Keychain, whose reads took 8-20 s on
/// the main actor in the H7 walkthrough (Settings › Devices froze).
final class RecordingRelaySecretStore: RelaySecretStore, @unchecked Sendable {
    // @unchecked: `calls` behind `lock`; the store is a MemoryRelaySecretStore.
    struct Call: Equatable {
        var name: String
        var onMain: Bool
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    let store = MemoryRelaySecretStore()

    var calls: [Call] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded = [] } }

    private func record(_ name: String) {
        let onMain = Thread.isMainThread
        lock.withLock { recorded.append(Call(name: name, onMain: onMain)) }
    }

    func secret(relayID: String) -> RelaySecret? {
        record("secret")
        return store.secret(relayID: relayID)
    }

    func save(_ secret: RelaySecret, relayID: String) {
        record("save")
        store.save(secret, relayID: relayID)
    }

    func remove(relayID: String) {
        record("remove")
        store.remove(relayID: relayID)
    }

    func relayIDs() -> [String] {
        record("relayIDs")
        return store.relayIDs()
    }
}

/// Relay secrets live in the Keychain, which can block for seconds: the hub
/// reads and writes them off the main actor and the UI reads what it loaded.
@MainActor @Suite struct DeviceHubRelaySecretTests {
    let me = DeviceIdentity.software()

    private func relaysStub(sealedTo identity: DeviceIdentity) throws -> StubHub {
        let blob = try RelaySealing.seal(.sharedSecret("turn-secret"), relayID: "r1", to: identity.agreementKey)
        return StubHub.routes(["GET /v1/relays": (200, #"{"relays":[{"id":"r1","name":"Home","urls":["turns:home:5349"],"authMode":"shared_secret","sealed":{"\#(identity.id)":"\#(blob)"},"enabled":true,"priority":0},{"id":"r2","name":"Lab","urls":["turn:lab:3478"],"authMode":"static","sealed":{},"enabled":true,"priority":1}]}"#)])
    }

    /// The Settings card's state reads `relaySecret` for every relay on each
    /// change: it must answer from memory, never from the store.
    @Test func readingASecretTouchesNoStore() async throws {
        let secrets = RecordingRelaySecretStore()
        secrets.store.save(.static(username: "u", password: "p"), relayID: "r2")
        let hub = DeviceHub(client: makeClient(try relaysStub(sealedTo: me), identity: me), secrets: secrets,
                            deviceName: "Studio", now: fixedNow)
        await hub.refreshRelays()
        secrets.reset()
        #expect(hub.relaySecret("r1") == .sharedSecret("turn-secret"))
        #expect(hub.relaySecret("r2") == .static(username: "u", password: "p"))
        #expect(hub.relaySecret("missing") == nil)
        #expect(hub.iceServers().count == 2)
        #expect(secrets.calls.isEmpty, "store calls on a read: \(secrets.calls)")
    }

    /// Loading, pruning and saving secrets after a relays listing runs off the main thread.
    @Test func refreshingRelaysUsesTheStoreOffTheMainThread() async throws {
        let secrets = RecordingRelaySecretStore()
        secrets.store.save(.sharedSecret("old"), relayID: "gone")
        let hub = DeviceHub(client: makeClient(try relaysStub(sealedTo: me), identity: me), secrets: secrets,
                            deviceName: "Studio", now: fixedNow)
        await hub.refreshRelays()
        #expect(!secrets.calls.isEmpty)
        #expect(secrets.calls.allSatisfy { !$0.onMain }, "store calls on the main thread: \(secrets.calls.filter(\.onMain))")
        #expect(secrets.store.secret(relayID: "gone") == nil)
        #expect(secrets.store.secret(relayID: "r1") == .sharedSecret("turn-secret"))
    }

    /// Saving and deleting a relay keep the store in step, off the main thread, and the
    /// in-memory secret follows at once.
    @Test func savingAndDeletingARelayUseTheStoreOffTheMainThread() async throws {
        let me = self.me
        let stub = StubHub { request in
            switch (request.method, request.url.path) {
            case (_, "/v1/auth/stack"): return (200, #"{"session":"hub-session","userId":"u","expiresAt":1800003600000}"#)
            case ("GET", "/v1/devices"): return (200, devicesJSON([(me, "Studio")]))
            case ("PUT", _): return (200, #"{"relay":{"id":"r9","name":"Home","urls":["turn:h"],"authMode":"static","enabled":true,"priority":1}}"#)
            case ("DELETE", _): return (200, "{}")
            default: return (200, #"{"relays":[]}"#)
            }
        }
        let secrets = RecordingRelaySecretStore()
        let hub = DeviceHub(client: makeClient(stub, identity: me), secrets: secrets, deviceName: "Studio", now: fixedNow)
        try await hub.saveRelay(id: "r9", name: "Home", urls: ["turn:h"], secret: .static(username: "u", password: "p"), priority: 1)
        #expect(hub.relaySecret("r9") == .static(username: "u", password: "p"))
        #expect(secrets.store.secret(relayID: "r9") == .static(username: "u", password: "p"))
        try await hub.deleteRelay("r9")
        #expect(hub.relaySecret("r9") == nil)
        #expect(secrets.store.secret(relayID: "r9") == nil)
        #expect(secrets.calls.allSatisfy { !$0.onMain }, "store calls on the main thread: \(secrets.calls.filter(\.onMain))")
    }
}

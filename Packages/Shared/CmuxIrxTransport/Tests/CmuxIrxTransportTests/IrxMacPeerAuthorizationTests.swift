import CmuxIrohTransport
import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite("Automatic Mac peer authorization")
struct IrxMacPeerAuthorizationTests {
    private let device = "22222222-2222-4222-8222-222222222222"
    private let local = "11111111-1111-4111-8111-111111111111"
    private let endpoint = String(repeating: "ab", count: 32)
    private let bindingID = "33333333-3333-4333-8333-333333333333"

    private func binding(tag: String = "feature", enabled: Bool = true) throws -> CmxIrohBrokerBinding {
        let object: [String: Any] = [
            "binding_id": bindingID, "device_id": device,
            "app_instance_id": "44444444-4444-4444-8444-444444444444",
            "client_namespace": "mac:com.cmuxterm.app.debug.feature",
            "tag": tag, "platform": "mac", "endpoint_id": endpoint,
            "identity_generation": 1, "pairing_enabled": enabled,
            "capabilities": ["cmux.irx.v1"], "path_hints": [], "last_seen_at": "2026-09-10T00:00:00Z"
        ]
        return try JSONDecoder().decode(CmxIrohBrokerBinding.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func lease(now: ContinuousClock.Instant, revoked: Bool = false, bindingID: String? = nil) -> IrxDeviceListSnapshot {
        IrxDeviceListSnapshot(
            entries: [endpoint: IrxDeviceListEntry(
                deviceID: device, status: "active", revoked: revoked,
                bindingID: bindingID ?? self.bindingID, tag: "feature", identityGeneration: 1
            )],
            rev: 1, issuedAt: Date(), ttlSeconds: 60,
            receivedAtWall: Date(), receivedAtMonotonic: now
        )
    }

    @Test("The complete matching broker and device-list tuple authorizes the Mac")
    func acceptsMatchingPeer() throws {
        let now = ContinuousClock.now
        let intent = IrxMacPeerAuthorization(deviceID: device, tag: "feature", endpointID: endpoint)
        let selected = try intent.resolve(bindings: [binding()], lease: lease(now: now), localDeviceID: local, now: now)
        #expect(selected.bindingID == bindingID)
    }

    @Test("A discovered address never substitutes another build or a revoked binding")
    func rejectsUntrustedPeer() throws {
        let now = ContinuousClock.now
        let intent = IrxMacPeerAuthorization(deviceID: device, tag: "feature", endpointID: endpoint)
        #expect(throws: IrxMacPeerAuthorization.Failure.identityMismatch) {
            try intent.resolve(bindings: [binding(tag: "other")], lease: lease(now: now), localDeviceID: local, now: now)
        }
        #expect(throws: IrxMacPeerAuthorization.Failure.identityMismatch) {
            try intent.resolve(bindings: [binding()], lease: lease(now: now, bindingID: "replaced"), localDeviceID: local, now: now)
        }
        #expect(throws: IrxMacPeerAuthorization.Failure.revoked) {
            try intent.resolve(bindings: [binding()], lease: lease(now: now, revoked: true), localDeviceID: local, now: now)
        }
        #expect(throws: IrxMacPeerAuthorization.Failure.unavailable) {
            try intent.resolve(bindings: [binding(enabled: false)], lease: lease(now: now), localDeviceID: local, now: now)
        }
        #expect(throws: IrxMacPeerAuthorization.Failure.staleDirectory) {
            try intent.resolve(bindings: [binding()], lease: lease(now: now), localDeviceID: local, now: now.advanced(by: .seconds(60)))
        }
        #expect(throws: IrxMacPeerAuthorization.Failure.identityMismatch) {
            try intent.resolve(bindings: [binding()], lease: lease(now: now), localDeviceID: device, now: now)
        }
    }
}

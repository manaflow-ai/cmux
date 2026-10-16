import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite("Mac discoverability denial reasons")
struct IrxMacDiscoverabilityTests {
    private let device = "22222222-2222-4222-8222-222222222222"
    private let local = "11111111-1111-4111-8111-111111111111"
    private let endpoint = String(repeating: "ab", count: 32)
    private let recordID = "33333333-3333-4333-8333-333333333333"

    private func identity(device: String, user: String = "owner", tag: String = "feature") -> V2Identity {
        V2Identity(appNamespace: "com.cmux.debug.feature", buildTag: tag, deviceID: device,
            environment: "development", projectID: "project", teamID: "team", userID: user)
    }

    private func record(device: String, endpoint: String, enabled: Bool = true, hosting: Bool = true,
                        user: String = "owner", tag: String = "feature", revoked: Bool = false) -> V2DeviceRecord {
        let descriptor = V2DeviceDescriptor(endpointID: endpoint, identity: identity(device: device, user: user, tag: tag),
            identityGeneration: 1, metadata: V2DeviceMetadata(appVersion: "1", capabilities: ["cmux.mac-devices.v1"] + (hosting ? ["cmux.mac-host.v1"] : []),
                displayName: "Mac", pairingEnabled: enabled, platform: .mac, relayURLs: ["https://relay.test"]))
        return V2DeviceRecord(descriptor: descriptor, deviceRecordID: recordID, revision: 1, revoked: revoked)
    }

    private func cache(peer: V2DeviceRecord? = nil) -> V2CachedState {
        var state = V2CachedState(identity: identity(device: local))
        state.device = record(device: local, endpoint: String(repeating: "cd", count: 32), enabled: false)
        state.directory = V2Directory(devices: [peer ?? record(device: device, endpoint: endpoint)],
            issuedAt: 1000, permissionExpiresAt: 1060, relayURLs: ["https://relay.test"], revision: 1, teamID: "team")
        return state
    }

    @Test("A discoverable Mac remains authorized with iOS pairing either on or off", arguments: [false, true])
    func hostingRemainsIndependentFromMobilePairing(mobilePairing: Bool) throws {
        let state = cache(peer: record(device: device, endpoint: endpoint, enabled: mobilePairing))
        let selected = try IrxMacPeerAuthorization(deviceID: device, tag: "feature", endpointID: endpoint)
            .resolve(cache: state, localIdentity: state.identity, now: Date(timeIntervalSince1970: 1001))
        #expect(selected.descriptor.identity.deviceID == device)
    }

    @Test("Known Mac opt-out is distinct from a missing peer, independently of iOS pairing", arguments: [false, true])
    func disabledHostingHasItsOwnFailure(mobilePairing: Bool) throws {
        let intent = IrxMacPeerAuthorization(deviceID: device, tag: "feature", endpointID: endpoint)
        let disabled = cache(peer: record(device: device, endpoint: endpoint, enabled: mobilePairing, hosting: false))
        let missing = cache(peer: record(device: device, endpoint: String(repeating: "ef", count: 32)))
        func failure(_ state: V2CachedState) -> IrxMacPeerAuthorization.Failure? {
            do {
                _ = try intent.resolve(cache: state, localIdentity: state.identity, now: Date(timeIntervalSince1970: 1001))
                return nil
            } catch { return error as? IrxMacPeerAuthorization.Failure }
        }
        let disabledFailure = try #require(failure(disabled))
        let missingFailure = try #require(failure(missing))
        #expect(disabledFailure != missingFailure, "Only an authenticated matching record proves discoverability is off")
        #expect(disabledFailure != .identityMismatch)
    }

    @Test("An opt-out never masks an invalid identity, revoked device or stale directory")
    func disabledHostingPreservesSecurityFailures() {
        let intent = IrxMacPeerAuthorization(deviceID: device, tag: "feature", endpointID: endpoint)
        let foreign = cache(peer: record(device: device, endpoint: endpoint, hosting: false, user: "other"))
        #expect(throws: IrxMacPeerAuthorization.Failure.identityMismatch) {
            try intent.resolve(cache: foreign, localIdentity: foreign.identity, now: Date(timeIntervalSince1970: 1001))
        }
        let revoked = cache(peer: record(device: device, endpoint: endpoint, hosting: false, revoked: true))
        #expect(throws: IrxMacPeerAuthorization.Failure.revoked) {
            try intent.resolve(cache: revoked, localIdentity: revoked.identity, now: Date(timeIntervalSince1970: 1001))
        }
        let stale = cache(peer: record(device: device, endpoint: endpoint, hosting: false))
        #expect(throws: IrxMacPeerAuthorization.Failure.staleDirectory) {
            try intent.resolve(cache: stale, localIdentity: stale.identity, now: Date(timeIntervalSince1970: 1060))
        }
    }

}

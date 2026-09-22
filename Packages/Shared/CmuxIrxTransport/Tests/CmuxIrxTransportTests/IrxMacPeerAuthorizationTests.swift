import Foundation
import Testing
@testable import CmuxIrxTransport

@Suite("Automatic Mac v2 peer authorization")
struct IrxMacPeerAuthorizationTests {
    private let device = "22222222-2222-4222-8222-222222222222"
    private let local = "11111111-1111-4111-8111-111111111111"
    private let endpoint = String(repeating: "ab", count: 32)
    private let recordID = "33333333-3333-4333-8333-333333333333"

    private func identity(device: String, user: String = "owner", tag: String = "feature") -> V2Identity {
        V2Identity(appNamespace: "com.cmux.debug.feature", buildTag: tag, deviceID: device,
            environment: "development", projectID: "project", teamID: "team", userID: user)
    }

    private func record(device: String, endpoint: String, enabled: Bool = true,
                        user: String = "owner", tag: String = "feature", revoked: Bool = false) -> V2DeviceRecord {
        let descriptor = V2DeviceDescriptor(endpointID: endpoint, identity: identity(device: device, user: user, tag: tag),
            identityGeneration: 1, metadata: V2DeviceMetadata(appVersion: "1", capabilities: ["cmux.mac-devices.v1", "cmux.mac-host.v1"],
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

    @Test("An outgoing-only Mac can use its own account's host permission")
    func acceptsMatchingPeer() throws {
        let state = cache()
        let selected = try IrxMacPeerAuthorization(deviceID: device, tag: "feature", endpointID: endpoint)
            .resolve(cache: state, localIdentity: state.identity, now: Date(timeIntervalSince1970: 1001))
        #expect(selected.deviceRecordID == recordID)
    }

    @Test("Discovery-only control does not authorize incoming sessions")
    func outgoingOnlyControlHasNoInboundAuthority() throws {
        let own = record(device: local, endpoint: String(repeating: "cd", count: 32), enabled: false)
        _ = try V2ControlConfiguration(baseURL: URL(string: "https://broker.test")!, device: own.descriptor)
        let authority = try V2InboundAdmissionAuthority(host: own.descriptor)
        #expect(authority.authorizedPeer(endpointID: endpoint) == nil)
    }

    @Test("Remote identities and disabled hosts fail closed")
    func rejectsUntrustedPeer() throws {
        let intent = IrxMacPeerAuthorization(deviceID: device, tag: "feature", endpointID: endpoint)
        let invalid = [
            record(device: device, endpoint: endpoint, tag: "other"),
            record(device: device, endpoint: endpoint, user: "other"),
            record(device: device, endpoint: endpoint, enabled: false),
            record(device: device, endpoint: endpoint, revoked: true),
            record(device: local, endpoint: endpoint)
        ]
        for peer in invalid {
            let state = cache(peer: peer)
            #expect(throws: (any Error).self) {
                try intent.resolve(cache: state, localIdentity: state.identity, now: Date(timeIntervalSince1970: 1001))
            }
        }
    }

    @Test("Expiry, duplicate peers and a revoked local scope cannot authorize")
    func rejectsStaleOrAmbiguousAuthority() {
        let intent = IrxMacPeerAuthorization(deviceID: device, tag: "feature", endpointID: endpoint)
        var state = cache()
        #expect(throws: IrxMacPeerAuthorization.Failure.staleDirectory) {
            try intent.resolve(cache: state, localIdentity: state.identity, now: Date(timeIntervalSince1970: 1060))
        }
        state.authorityRevoked = true
        #expect(throws: IrxMacPeerAuthorization.Failure.revoked) {
            try intent.resolve(cache: state, localIdentity: state.identity, now: Date(timeIntervalSince1970: 1001))
        }
        state = cache()
        let peer = record(device: device, endpoint: endpoint)
        state.directory = V2Directory(devices: [peer, peer], issuedAt: 1000,
            permissionExpiresAt: 1060, relayURLs: [], revision: 1, teamID: "team")
        #expect(throws: IrxMacPeerAuthorization.Failure.identityMismatch) {
            try intent.resolve(cache: state, localIdentity: state.identity, now: Date(timeIntervalSince1970: 1001))
        }
    }
}

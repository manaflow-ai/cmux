import Foundation
import os
import Testing
@testable import CmuxIrxTransport

@Suite(.timeLimit(.minutes(1)))
struct V2InboundAdmissionAuthorityTests {
    private let timestamp = 1_789_000_000

    private func device(key: String = "a", deviceID: String = "host", generation: Int = 1,
                        team: String = "team", environment: String = "development",
                        project: String = "project", platform: V2Platform = .mac) -> V2DeviceDescriptor {
        V2DeviceDescriptor(endpointID: String(repeating: key, count: 64),
            identity: V2Identity(appNamespace: platform == .mac ? "com.cmux.mac" : "dev.cmux.ios",
                buildTag: "tag", deviceID: deviceID, environment: environment, projectID: project,
                teamID: team, userID: platform == .mac ? "host-owner" : "permitted-teammate"),
            identityGeneration: generation, metadata: V2DeviceMetadata(appVersion: "2", capabilities: [],
                displayName: deviceID, pairingEnabled: true, platform: platform, relayURLs: []))
    }

    private func peer(key: String = "b", deviceID: String = "phone", generation: Int = 1,
                      team: String = "team", environment: String = "development", project: String = "project",
                      revoked: Bool = false, expiry: Int? = nil) -> V2InboundPeerPermission {
        V2InboundPeerPermission(device: V2DeviceRecord(descriptor: device(key: key, deviceID: deviceID,
            generation: generation, team: team, environment: environment, project: project, platform: .ios),
            deviceRecordID: "record-" + deviceID, revision: 1, revoked: revoked),
            permissionExpiresAt: expiry ?? timestamp + 100)
    }

    private func cache(peers: [V2InboundPeerPermission]? = nil, revision: Int = 1, issuedAt: Int? = nil,
                       expiry: Int? = nil, outbound: [V2DeviceRecord] = [], host: V2DeviceDescriptor? = nil,
                       nextCursor: String? = nil) -> V2CachedState {
        let host = host ?? device()
        var cache = V2CachedState(identity: host.identity)
        cache.device = V2DeviceRecord(descriptor: host, deviceRecordID: "host-record", revision: 1, revoked: false)
        cache.directory = V2Directory(devices: outbound, inboundPeers: peers, issuedAt: issuedAt ?? timestamp,
            nextCursor: nextCursor, permissionExpiresAt: expiry ?? timestamp + 100,
            relayURLs: [], revision: revision, teamID: host.identity.teamID)
        return cache
    }

    private func snapshot(_ cache: V2CachedState, sequence: UInt64) -> V2ControlSnapshot {
        V2ControlSnapshot(status: .ready, cache: cache, failure: nil, sequence: sequence)
    }

    private func authority(_ clock: V2AdmissionTestClock) throws -> V2InboundAdmissionAuthority {
        try V2InboundAdmissionAuthority(host: device(), wallNow: { clock.wall }, monotonicNow: { clock.monotonic })
    }

    @Test func onlyInboundPermissionsGrantAccessToTheTLSKey() throws {
        let authority = try authority(V2AdmissionTestClock(wall: timestamp))
        let permitted = peer()
        let outbound = peer(key: "c", deviceID: "ungranted").device
        #expect(authority.restore(cache(peers: [permitted], outbound: [outbound])))
        let receipt = try authority.judgment()("legacy-grant-is-ignored", permitted.device.descriptor.endpointID)
        #expect(receipt.bindingID == permitted.device.deviceRecordID)
        #expect(receipt.deviceID == "phone")
        #expect(receipt.identityGeneration == 1)
        #expect(authority.authorizedPeer(endpointID: outbound.descriptor.endpointID) == nil)
        #expect(authority.authorizedPeer(endpointID: device().endpointID) == nil)
        #expect(authority.recheck(receipt)(permitted.device.descriptor.endpointID))
        #expect(!authority.recheck(receipt)(outbound.descriptor.endpointID))
    }

    @Test func missingInboundFieldNeverUsesTheOutboundDirectory() throws {
        let authority = try authority(V2AdmissionTestClock(wall: timestamp))
        let outbound = peer().device
        _ = authority.restore(cache(outbound: [outbound]))
        #expect(authority.authorizedPeer(endpointID: outbound.descriptor.endpointID) == nil)
        #expect(authority.nextExpiration == nil)
    }

    @Test func anotherCacheFormatCannotEstablishOrPreserveAuthority() throws {
        let valid = cache(peers: [peer()])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["formatVersion"] = 1
        let legacy = try JSONDecoder().decode(V2CachedState.self, from: JSONSerialization.data(withJSONObject: object))
        let restored = try authority(V2AdmissionTestClock(wall: timestamp))
        _ = restored.restore(legacy)
        _ = restored.apply(snapshot(valid, sequence: 1))
        #expect(restored.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
        let live = try authority(V2AdmissionTestClock(wall: timestamp))
        _ = live.restore(valid)
        _ = live.apply(snapshot(legacy, sequence: 1))
        #expect(live.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
    }

    @Test func foreignTeamProjectEnvironmentAndRevokedPeersAreDenied() throws {
        let authority = try authority(V2AdmissionTestClock(wall: timestamp))
        let peers = [peer(key: "b", team: "other"), peer(key: "c", environment: "production"),
                     peer(key: "d", project: "other"), peer(key: "e", revoked: true)]
        _ = authority.restore(cache(peers: peers))
        for peer in peers { #expect(authority.authorizedPeer(endpointID: peer.device.descriptor.endpointID) == nil) }
        _ = authority.apply(snapshot(cache(peers: [peer(key: "e")], revision: 2, issuedAt: timestamp + 1), sequence: 1))
        #expect(authority.authorizedPeer(endpointID: String(repeating: "e", count: 64)) == nil)
    }

    @Test func deadlinesUseTheEarlierPeerOrDirectoryExpiryWithoutWallClockResurrection() throws {
        let clock = V2AdmissionTestClock(wall: timestamp)
        let authority = try authority(clock)
        let first = peer(expiry: timestamp + 10)
        let second = peer(key: "c", deviceID: "other-phone", expiry: timestamp + 30)
        let initial = cache(peers: [first, second], expiry: timestamp + 20)
        _ = authority.restore(initial)
        #expect(authority.nextExpiration == clock.monotonic.advanced(by: .seconds(10)))
        clock.advance(10)
        #expect(authority.authorizedPeer(endpointID: first.device.descriptor.endpointID) == nil)
        #expect(authority.authorizedPeer(endpointID: second.device.descriptor.endpointID) != nil)
        #expect(authority.nextExpiration == clock.monotonic.advanced(by: .seconds(10)))
        clock.rewindWall(3600)
        _ = authority.apply(snapshot(initial, sequence: 1))
        #expect(authority.nextExpiration == clock.monotonic.advanced(by: .seconds(10)))
        clock.advance(10)
        #expect(authority.authorizedPeer(endpointID: second.device.descriptor.endpointID) == nil)
        #expect(authority.nextExpiration == nil)
        #expect(throws: IrxAdmissionDenied(code: .grantExpired)) {
            try authority.judgment()(nil, second.device.descriptor.endpointID)
        }
    }

    @Test func freshSnapshotAfterWallRollbackDoesNotExtendAnUnchangedExpiry() throws {
        let clock = V2AdmissionTestClock(wall: timestamp)
        let authority = try authority(clock)
        let original = cache(peers: [peer(expiry: timestamp + 20)], expiry: timestamp + 20)
        _ = authority.restore(original)
        let deadline = authority.nextExpiration
        clock.advance(10)
        clock.rewindWall(3600)
        _ = authority.apply(snapshot(cache(peers: [peer(expiry: timestamp + 20)], revision: 2,
            issuedAt: timestamp + 5, expiry: timestamp + 20), sequence: 1))
        #expect(authority.nextExpiration == deadline)
    }

    @Test func restoredAuthoritySurvivesOnlyTheInitialEmptyPublication() throws {
        let authority = try authority(V2AdmissionTestClock(wall: timestamp))
        let initial = cache(peers: [peer()])
        let empty = V2CachedState(identity: device().identity)
        _ = authority.restore(initial)
        #expect(!authority.apply(snapshot(empty, sequence: 1)))
        #expect(authority.authorizedPeer(endpointID: peer().device.descriptor.endpointID) != nil)
        _ = authority.apply(snapshot(initial, sequence: 2))
        #expect(authority.apply(snapshot(empty, sequence: 3)))
        #expect(authority.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
        #expect(!authority.restore(initial))
        #expect(!authority.apply(snapshot(initial, sequence: 2)))
        #expect(!authority.apply(snapshot(initial, sequence: 4)))
        #expect(authority.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
    }

    @Test func staleSnapshotsAndFreshRestampsCannotUndoKnownRevocation() throws {
        let authority = try authority(V2AdmissionTestClock(wall: timestamp))
        let granted = peer()
        _ = authority.apply(snapshot(cache(peers: [granted]), sequence: 1))
        let admitted = try #require(authority.authorizedPeer(endpointID: granted.device.descriptor.endpointID))
        let recheck = authority.recheck(admitted)
        #expect(authority.revoke(V2RevokedResponse(deviceRecordID: granted.device.deviceRecordID,
            revision: 2, schemaID: .deviceRevokedV1, teamID: "team")))
        #expect(!recheck(admitted.endpointIDHex))
        _ = authority.apply(snapshot(cache(peers: [granted]), sequence: 2))
        _ = authority.apply(snapshot(cache(peers: [granted], revision: 3, issuedAt: timestamp + 1), sequence: 3))
        #expect(!recheck(admitted.endpointIDHex))
    }

    @Test func replacementGenerationCannotReuseAnOldAdmissionReceipt() throws {
        let authority = try authority(V2AdmissionTestClock(wall: timestamp))
        _ = authority.restore(cache(peers: [peer()]))
        let key = peer().device.descriptor.endpointID
        let admitted = try #require(authority.authorizedPeer(endpointID: key))
        _ = authority.apply(snapshot(cache(peers: [peer(generation: 2)], revision: 2,
            issuedAt: timestamp + 1), sequence: 1))
        #expect(authority.authorizedPeer(endpointID: key)?.identityGeneration == 2)
        #expect(!authority.recheck(admitted)(key))
    }

    @Test func wrongLocalTupleKeyOrGenerationInvalidatesTheOwner() throws {
        for wrong in [device(key: "f"), device(generation: 2), device(team: "other"),
                      device(environment: "production"), device(project: "other")] {
            let authority = try authority(V2AdmissionTestClock(wall: timestamp))
            _ = authority.restore(cache(peers: [peer()]))
            _ = authority.apply(snapshot(cache(peers: [peer()], host: wrong), sequence: 1))
            _ = authority.apply(snapshot(cache(peers: [peer()], revision: 2, issuedAt: timestamp + 1), sequence: 2))
            #expect(authority.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
        }
    }

    @Test func partialDirectoryAndDuplicateKeyOrTupleNeverGrantAccess() throws {
        for candidates in [[peer(), peer(deviceID: "other")], [peer(), peer(key: "c")]] {
            let authority = try authority(V2AdmissionTestClock(wall: timestamp))
            _ = authority.restore(cache(peers: candidates))
            #expect(authority.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
        }
        let authority = try authority(V2AdmissionTestClock(wall: timestamp))
        _ = authority.restore(cache(peers: [peer()], nextCursor: "page-2"))
        #expect(authority.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
    }

    @Test func ownRevocationAndConcurrentInvalidationArePermanent() async throws {
        let authority = try authority(V2AdmissionTestClock(wall: timestamp))
        let source = cache(peers: [peer()])
        _ = authority.restore(source)
        await withTaskGroup(of: Void.self) { group in
            for sequence in 1...32 {
                let snapshot = snapshot(source, sequence: UInt64(sequence))
                group.addTask { _ = authority.apply(snapshot) }
            }
            group.addTask { authority.invalidate() }
        }
        #expect(authority.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
        #expect(authority.nextExpiration == nil)
        let second = try self.authority(V2AdmissionTestClock(wall: timestamp))
        _ = second.restore(source)
        #expect(second.revoke(V2RevokedResponse(deviceRecordID: "host-record", revision: 2,
            schemaID: .deviceRevokedV1, teamID: "team")))
        #expect(second.authorizedPeer(endpointID: peer().device.descriptor.endpointID) == nil)
    }
}

private final class V2AdmissionTestClock: Sendable {
    private struct State: Sendable { var wall: Date; var monotonic: ContinuousClock.Instant }
    private let state: OSAllocatedUnfairLock<State>
    init(wall: Int) { state = OSAllocatedUnfairLock(initialState: State(wall: Date(timeIntervalSince1970: Double(wall)), monotonic: .now)) }
    var wall: Date { state.withLock { $0.wall } }
    var monotonic: ContinuousClock.Instant { state.withLock { $0.monotonic } }
    func advance(_ seconds: Int) {
        state.withLock { $0.wall.addTimeInterval(Double(seconds)); $0.monotonic = $0.monotonic.advanced(by: .seconds(seconds)) }
    }
    func rewindWall(_ seconds: Int) { state.withLock { $0.wall.addTimeInterval(-Double(seconds)) } }
}

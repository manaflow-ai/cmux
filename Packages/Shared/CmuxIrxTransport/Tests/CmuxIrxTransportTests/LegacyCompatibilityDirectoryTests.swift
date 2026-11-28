import Foundation
import Testing
@testable import CmuxIrxTransport

struct LegacyCompatibilityDirectoryTests {
    @Test func modernPeerCannotRegainLegacyAuthorityWhenMarkerDisappears() {
        var directory = LegacyCompatibilityDirectory()
        directory.apply(snapshot(revision: 1, capabilities: [LegacyCompatibilityService.v2Capability]))
        #expect(directory.current?.entries[endpoint] == nil)
        directory.apply(snapshot(revision: 2, capabilities: []))
        #expect(directory.current?.entries[endpoint] == nil)
    }

    @Test func explicitV2RevocationWinsOverFreshLegacyRegistration() {
        var directory = LegacyCompatibilityDirectory()
        directory.apply(snapshot(revision: 1, capabilities: []))
        #expect(directory.current?.entries[endpoint] != nil)
        directory.excludeV2Endpoints([endpoint])
        #expect(directory.current?.entries[endpoint] == nil)
        directory.apply(snapshot(revision: 2, capabilities: []))
        #expect(directory.current?.entries[endpoint] == nil)
    }

    @Test func olderDirectoryCannotUndoRevocation() {
        var directory = LegacyCompatibilityDirectory()
        directory.apply(snapshot(revision: 3, capabilities: [], revoked: true))
        directory.apply(snapshot(revision: 2, capabilities: []))
        #expect(directory.current?.entries[endpoint]?.revoked == true)
    }

    @Test func stopRemovesAuthorityAndDisallowsLateCallbacks() {
        var directory = LegacyCompatibilityDirectory()
        directory.apply(snapshot(revision: 1, capabilities: []))
        directory.stop()
        directory.apply(snapshot(revision: 2, capabilities: []))
        #expect(directory.current == nil)
    }

    @Test func freshnessCannotRestoreAnExcludedPeer() {
        var directory = LegacyCompatibilityDirectory()
        let original = snapshot(revision: 1, capabilities: [])
        directory.apply(original)
        directory.excludeV2Endpoints([endpoint])
        directory.restamp(revision: 1, issuedAt: original.issuedAt.addingTimeInterval(10),
                          receivedAtWall: Date(), receivedAtMonotonic: .now)
        #expect(directory.current?.entries[endpoint] == nil)
    }

    private var endpoint: String { String(repeating: "a", count: 64) }

    private func snapshot(revision: Int, capabilities: [String], revoked: Bool = false) -> IrxDeviceListSnapshot {
        IrxDeviceListSnapshot(entries: [endpoint: IrxDeviceListEntry(
            deviceID: "device", status: "active", revoked: revoked, capabilities: capabilities,
            bindingID: "binding", tag: "default", identityGeneration: 1
        )], rev: revision, issuedAt: Date(), ttlSeconds: 3600,
            receivedAtWall: Date(), receivedAtMonotonic: .now)
    }
}

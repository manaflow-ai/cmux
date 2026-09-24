import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacV2IdentityMigrationTests {
    private func route(_ byte: String = "a") throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "iroh-\(byte)", kind: .iroh,
                           endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: byte, count: 64)),
                                           pathHints: []))
    }

    private func save(_ store: MobilePairedMacStore, id: String, tag: String = "nightly",
                      user: String = "alice", team: String? = "team-a", endpoint: String = "a",
                      active: Bool = true) async throws {
        try await store.upsert(macDeviceID: id, displayName: "Same name", routes: [route(endpoint)],
                               instanceTag: tag, markActive: active, stackUserID: user,
                               teamID: team, now: Date(timeIntervalSince1970: 100))
    }

    private func fixture() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("macs.sqlite3")), directory)
    }

    @Test func repairsAlreadyImportedDuplicatesAndReplaysPreferenceMappingAfterRestart() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await save(store, id: "old")
        try await store.setCustomization(macDeviceID: "old", instanceTag: "nightly", customName: "Office",
                                         customColor: "palette:2", customIcon: "house", stackUserID: "alice",
                                         teamID: "team-a", now: Date(timeIntervalSince1970: 101))
        try await store.setConnectionMethod(macDeviceID: "old", instanceTag: "nightly", rawValue: "direct",
                                            stackUserID: "alice", teamID: "team-a")
        try await store.setDirectAddresses(macDeviceID: "old", instanceTag: "nightly", rawJSON: "[]",
                                          stackUserID: "alice", teamID: "team-a")
        try await save(store, id: "new", active: false)
        try await store.setCustomization(macDeviceID: "new", instanceTag: "nightly", customName: "New choice",
                                         customColor: nil, customIcon: nil, stackUserID: "alice",
                                         teamID: "team-a", now: Date(timeIntervalSince1970: 102))
        let evidence = [MobilePairedMacDirectoryIdentity(deviceID: "new", instanceTag: "nightly", routes: [try route()])]
        let aliases = try await store.reconcileLegacyIdentities(with: evidence, stackUserID: "alice", teamID: "team-a")
        let rows = try await store.loadAll(stackUserID: "alice", teamID: "team-a")
        let mac = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(mac.macDeviceID == "new")
        #expect(mac.customName == "New choice")
        #expect(mac.customColor == "palette:2")
        #expect(mac.customIcon == "house")
        #expect(mac.connectionMethodRawValue == "direct")
        #expect(mac.directAddressesRawJSON == "[]")
        #expect(mac.isActive)
        #expect(mac.legacyTailscaleRoutes?.isEmpty != false)
        #expect(aliases.count == 1)
        let reopened = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("macs.sqlite3"))
        #expect(try await reopened.reconcileLegacyIdentities(with: evidence, stackUserID: "alice", teamID: "team-a") == aliases)
        #expect(try await reopened.loadAll() == rows)
    }

    @Test func refusesNamesAmbiguousEndpointsAndOtherOwnerScopes() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await save(store, id: "old")
        try await save(store, id: "old", tag: "default")
        try await save(store, id: "old", user: "bob")
        try await save(store, id: "old", team: "team-b")
        try await save(store, id: "old", team: nil)
        let before = try await store.loadAll()
        let differentEndpoint = [MobilePairedMacDirectoryIdentity(deviceID: "new", instanceTag: "nightly", routes: [try route("b")])]
        #expect(try await store.reconcileLegacyIdentities(with: differentEndpoint, stackUserID: "alice", teamID: "team-a").isEmpty)
        let ambiguous = try ["new-one", "new-two"].map {
            MobilePairedMacDirectoryIdentity(deviceID: $0, instanceTag: "nightly", routes: [try route()])
        }
        #expect(try await store.reconcileLegacyIdentities(with: ambiguous, stackUserID: "alice", teamID: "team-a").isEmpty)
        #expect(try await store.loadAll() == before)
        let unique = [ambiguous[0]]
        #expect(try await store.reconcileLegacyIdentities(with: unique, stackUserID: "alice", teamID: "team-a").count == 1)
        let after = try await store.loadAll()
        #expect(after.count == before.count)
        #expect(after.filter { $0.macDeviceID == "old" }.count == 4)
    }

    @Test func failedTransactionLeavesOriginalRecordAndCanRetry() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await save(store, id: "old")
        let before = try await store.loadAll()
        try await store.exec("""
            CREATE TRIGGER reject_migration BEFORE DELETE ON paired_macs
            BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END;
            """)
        let evidence = [MobilePairedMacDirectoryIdentity(deviceID: "new", instanceTag: "nightly", routes: [try route()])]
        await #expect(throws: (any Error).self) {
            try await store.reconcileLegacyIdentities(with: evidence, stackUserID: "alice", teamID: "team-a")
        }
        #expect(try await store.loadAll() == before)
        try await store.exec("DROP TRIGGER reject_migration;")
        #expect(try await store.reconcileLegacyIdentities(with: evidence, stackUserID: "alice", teamID: "team-a").count == 1)
        #expect(try await store.loadAll().map(\.macDeviceID) == ["new"])
    }

    @Test func importsAnUnmodifiedLegacyDatabaseThenReconcilesWithoutReplayingOldPreferences() async throws {
        let (legacy, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await save(legacy, id: "old")
        try await legacy.setCustomization(macDeviceID: "old", instanceTag: "nightly", customName: "Old choice",
                                          customColor: nil, customIcon: nil, stackUserID: "alice",
                                          teamID: "team-a", now: Date(timeIntervalSince1970: 101))
        let original = try await legacy.loadAll()
        let destination = directory.appendingPathComponent("v2.sqlite3")
        let upgraded = try MobilePairedMacStore(databaseURL: destination,
            importingLegacyDatabaseURL: directory.appendingPathComponent("macs.sqlite3"))
        let evidence = [MobilePairedMacDirectoryIdentity(deviceID: "new", instanceTag: "nightly", routes: [try route()])]
        _ = try await upgraded.reconcileLegacyIdentities(with: evidence, stackUserID: "alice", teamID: "team-a")
        #expect(try await upgraded.loadAll().first?.customName == "Old choice")
        #expect(try await legacy.loadAll() == original)
        // The user clears the old custom name, then a stale source reappears.
        try await upgraded.setCustomization(macDeviceID: "new", instanceTag: "nightly", customName: nil,
                                            customColor: nil, customIcon: nil, stackUserID: "alice",
                                            teamID: "team-a", now: Date(timeIntervalSince1970: 102))
        try await save(upgraded, id: "old", active: false)
        try await upgraded.setCustomization(macDeviceID: "old", instanceTag: "nightly", customName: "Old choice",
                                            customColor: nil, customIcon: nil, stackUserID: "alice",
                                            teamID: "team-a", now: Date(timeIntervalSince1970: 101))
        _ = try await upgraded.reconcileLegacyIdentities(with: evidence, stackUserID: "alice", teamID: "team-a")
        let rows = try await upgraded.loadAll()
        #expect(rows.map(\.macDeviceID) == ["new"])
        #expect(rows.first?.customName == nil)
        let reopened = try MobilePairedMacStore(databaseURL: destination,
            importingLegacyDatabaseURL: directory.appendingPathComponent("macs.sqlite3"))
        #expect(try await reopened.loadAll() == rows)
    }
}

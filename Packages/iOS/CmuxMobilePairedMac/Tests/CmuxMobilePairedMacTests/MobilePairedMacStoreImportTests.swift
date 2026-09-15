import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacStoreImportTests {
    @Test func upgradePreservesSavedComputersWithoutChangingLegacyStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("legacy.sqlite3")
        let destinationURL = directory.appendingPathComponent("v2.sqlite3")
        let legacy = try MobilePairedMacStore(databaseURL: legacyURL)
        let route = try CmxAttachRoute(id: "direct", kind: .tailscale,
                                       endpoint: .hostPort(host: "100.64.0.1", port: 8443))
        let date = Date(timeIntervalSince1970: 1_000)
        for (user, team, tag) in [("alice", "team-a", "default"),
                                  ("alice", "team-b", "nightly"),
                                  ("bob", "team-a", "default")] {
            try await legacy.upsert(macDeviceID: "same-mac", displayName: "Mac", routes: [route],
                                    instanceTag: tag, markActive: true, stackUserID: user,
                                    teamID: team, now: date)
        }
        try await legacy.setCustomization(macDeviceID: "same-mac", instanceTag: "default",
                                          customName: "Home Mac", customColor: "palette:2", customIcon: "house",
                                          stackUserID: "alice", teamID: "team-a", now: date)
        try await legacy.setConnectionMethod(macDeviceID: "same-mac", instanceTag: "default",
                                              rawValue: "tailscale", stackUserID: "alice", teamID: "team-a")
        try await legacy.setDirectAddresses(macDeviceID: "same-mac", instanceTag: "default",
                                            rawJSON: "[{\"address\":\"192.168.1.10\",\"enabled\":true}]",
                                            stackUserID: "alice", teamID: "team-a")
        // Device-local route authority must never be created by moving metadata.
        try await legacy.authorizeUserTailscaleRoutes(macDeviceID: "same-mac", instanceTag: "default",
                                                     stackUserID: "alice", teamID: "team-a", routes: [route])
        let before = try await legacy.loadAll()
        let upgraded = try MobilePairedMacStore(databaseURL: destinationURL, importingLegacyDatabaseURL: legacyURL)
        let imported = try #require(try await upgraded.loadAll(stackUserID: "alice", teamID: "team-a").first)
        #expect(imported.customName == "Home Mac")
        #expect(imported.customColor == "palette:2")
        #expect(imported.customIcon == "house")
        #expect(imported.connectionMethodRawValue == "tailscale")
        #expect(imported.directAddresses.first?.address == "192.168.1.10")
        #expect(imported.routes == [route])
        #expect(imported.createdAt == date)
        #expect(imported.lastSeenAt == date)
        #expect(imported.isActive)
        #expect(imported.legacyTailscaleRoutes?.isEmpty != false)
        #expect(try await upgraded.loadAll().count == 3)
        #expect(try await legacy.loadAll() == before)
        #expect(try await upgraded.loadAll(stackUserID: "bob", teamID: "team-a").count == 1)

        try await upgraded.remove(macDeviceID: "same-mac", instanceTag: "default",
                                  stackUserID: "alice", teamID: "team-a")
        let reopened = try MobilePairedMacStore(databaseURL: destinationURL, importingLegacyDatabaseURL: legacyURL)
        #expect(try await reopened.loadAll(stackUserID: "alice", teamID: "team-a").isEmpty)
        #expect(try await reopened.loadAll().count == 2)
    }

    @Test func existingV2RowsWinAndUnrequestedImportsRemainIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("legacy.sqlite3")
        let destinationURL = directory.appendingPathComponent("production.sqlite3")
        let legacy = try MobilePairedMacStore(databaseURL: legacyURL)
        let destination = try MobilePairedMacStore(databaseURL: destinationURL)
        for (store, name) in [(legacy, "Old name"), (destination, "New name")] {
            try await store.upsert(macDeviceID: "mac", displayName: name, routes: [],
                                   instanceTag: "default", markActive: true,
                                   stackUserID: "alice", teamID: "team", now: Date())
        }
        let upgraded = try MobilePairedMacStore(databaseURL: destinationURL, importingLegacyDatabaseURL: legacyURL)
        #expect(try await upgraded.loadAll().first?.displayName == "New name")
        let otherEnvironment = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("development.sqlite3"))
        #expect(try await otherEnvironment.loadAll().isEmpty)
    }
}

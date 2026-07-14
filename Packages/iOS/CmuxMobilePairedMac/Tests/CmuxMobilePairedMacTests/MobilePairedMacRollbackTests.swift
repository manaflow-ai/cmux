import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacRollbackTests {
    @Test func rejectedTeamClaimRollsBackLegacyScopeAndSelectionAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let rejectedDate = Date(timeIntervalSince1970: 2_000)
        let originalRoute = try CmxAttachRoute(
            id: "original",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.4", port: 8443)
        )
        let rejectedRoute = try CmxAttachRoute(
            id: "rejected",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.5", port: 8443)
        )
        try await store.upsert(
            macDeviceID: "legacy",
            displayName: "Original",
            routes: [originalRoute],
            instanceTag: "original-instance",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: originalDate
        )
        try await store.setCustomization(
            macDeviceID: "legacy",
            customName: "My Mac",
            customColor: "palette:2",
            customIcon: "desktopcomputer",
            stackUserID: "user-1",
            teamID: nil,
            now: originalDate
        )
        try await store.upsert(
            macDeviceID: "active",
            displayName: "Active",
            routes: [originalRoute],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-1",
            now: originalDate
        )
        let previous = try #require(
            await store.loadAll(stackUserID: "user-1", teamID: "team-1")
                .first { $0.macDeviceID == "legacy" }
        )
        let previousActive = try #require(
            await store.activeMac(stackUserID: "user-1", teamID: "team-1")
        )

        try await store.upsert(
            macDeviceID: "legacy",
            displayName: "Rejected",
            routes: [rejectedRoute],
            instanceTag: "rejected-instance",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-1",
            now: rejectedDate
        )
        try await store.rollbackRejectedUpsert(MobilePairedMacUpsertRollback(
            rejectedMacDeviceID: "legacy",
            rejectedStackUserID: "user-1",
            rejectedTeamID: "team-1",
            previousMac: previous,
            previousActiveMac: previousActive,
            rejectedTimestamp: rejectedDate,
            now: rejectedDate
        ))

        let restored = try await store.loadAll(stackUserID: "user-1", teamID: "team-1")
        let legacy = try #require(restored.first { $0.macDeviceID == "legacy" })
        #expect(restored.filter { $0.macDeviceID == "legacy" }.count == 1)
        #expect(legacy.teamID == nil)
        #expect(legacy.createdAt == originalDate)
        #expect(legacy.lastSeenAt > rejectedDate)
        #expect(legacy.displayName == "Original")
        #expect(legacy.routes == [originalRoute])
        #expect(legacy.instanceTag == "original-instance")
        #expect(legacy.customName == "My Mac")
        #expect(legacy.customColor == "palette:2")
        #expect(legacy.customIcon == "desktopcomputer")
        #expect(legacy.isActive == false)
        #expect(restored.first { $0.macDeviceID == "active" }?.isActive == true)
    }
}

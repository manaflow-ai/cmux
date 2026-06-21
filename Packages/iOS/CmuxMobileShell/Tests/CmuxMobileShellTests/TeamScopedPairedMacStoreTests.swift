import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct TeamScopedPairedMacStoreTests {
    private func makeInnerStore() throws -> (MobilePairedMacStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        return (store, directory)
    }

    private func route(_ host: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: 22))
    }

    @Test func scopesConvenienceCallsByCurrentTeamWithoutBackup() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let team = MutableTeamID("team-a")
        let store = TeamScopedPairedMacStore(inner: inner, teamIDProvider: { await team.value })

        try await store.upsert(
            macDeviceID: "mac-a",
            displayName: "A",
            routes: [try route("10.0.0.1")],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(try await inner.loadAll(stackUserID: "user-1").first?.teamID == "team-a")
        #expect(try await store.loadAll(stackUserID: "user-1").map(\.macDeviceID) == ["mac-a"])

        await team.set("team-b")
        #expect(try await store.loadAll(stackUserID: "user-1").isEmpty)
        #expect(try await store.activeMac(stackUserID: "user-1") == nil)

        try await store.upsert(
            macDeviceID: "mac-b",
            displayName: "B",
            routes: [try route("10.0.0.2")],
            markActive: true,
            stackUserID: "user-1",
            now: Date(timeIntervalSince1970: 2)
        )

        #expect(try await store.loadAll(stackUserID: "user-1").map(\.macDeviceID) == ["mac-b"])
        #expect(try await inner.activeMac(stackUserID: "user-1", teamID: "team-b")?.macDeviceID == "mac-b")
        #expect(try await inner.activeMac(stackUserID: "user-1", teamID: "team-a")?.macDeviceID == "mac-a")

        await team.set("team-a")
        #expect(try await store.loadAll(stackUserID: "user-1").map(\.macDeviceID) == ["mac-a"])
    }
}

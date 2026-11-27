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

    @Test func customizationPreservesVisibleLegacyRowScope() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TeamScopedPairedMacStore(
            inner: inner,
            teamIDProvider: { "team-a" }
        )

        try await inner.upsert(
            macDeviceID: "mac-legacy",
            displayName: "Legacy",
            routes: [try route("10.0.0.1")],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )

        try await store.setCustomization(
            macDeviceID: "mac-legacy",
            customName: "Studio",
            customColor: "palette:4",
            customIcon: "terminal",
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )

        let visible = try await store.loadAll(stackUserID: "user-1").first { $0.macDeviceID == "mac-legacy" }
        #expect(visible?.teamID == nil)
        #expect(visible?.customName == "Studio")
        #expect(visible?.customColor == "palette:4")
        #expect(visible?.customIcon == "terminal")
    }

    @Test func activatingVisibleLegacyRowClearsSelectedTeamActiveMac() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TeamScopedPairedMacStore(
            inner: inner,
            teamIDProvider: { "team-a" }
        )

        try await inner.upsert(
            macDeviceID: "mac-legacy",
            displayName: "Legacy",
            routes: [try route("10.0.0.1")],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await inner.upsert(
            macDeviceID: "mac-team",
            displayName: "Team",
            routes: [try route("10.0.0.2")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        try await store.setActive(macDeviceID: "mac-legacy", stackUserID: "user-1", teamID: nil)

        let visible = try await store.loadAll(stackUserID: "user-1")
        #expect(visible.filter(\.isActive).map(\.macDeviceID) == ["mac-legacy"])
        #expect(try await store.activeMac(stackUserID: "user-1")?.macDeviceID == "mac-legacy")
    }
}

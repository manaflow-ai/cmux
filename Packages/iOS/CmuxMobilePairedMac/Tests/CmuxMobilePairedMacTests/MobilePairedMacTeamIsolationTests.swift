import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacTeamIsolationTests {
    @Test func sameMacDeviceIDCanExistInMultipleTeams() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-paired-mac-team-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let routeA = try CmxAttachRoute(id: "a", kind: .tailscale, endpoint: .hostPort(host: "10.0.0.1", port: 22))
        let routeB = try CmxAttachRoute(id: "b", kind: .tailscale, endpoint: .hostPort(host: "10.0.0.2", port: 22))

        try await store.upsert(macDeviceID: "shared-mac", displayName: "Team A Mac", routes: [routeA],
            markActive: true, stackUserID: "user-1", teamID: "team-a", now: Date(timeIntervalSince1970: 1))
        try await store.setCustomization(
            macDeviceID: "shared-mac",
            customName: "A custom",
            customColor: "palette:1",
            customIcon: "desktopcomputer",
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        try await store.upsert(macDeviceID: "shared-mac", displayName: "Team B Mac", routes: [routeB],
            markActive: true, stackUserID: "user-1", teamID: "team-b", now: Date(timeIntervalSince1970: 3))

        let teamA = try await store.loadAll(stackUserID: "user-1", teamID: "team-a")
        let teamB = try await store.loadAll(stackUserID: "user-1", teamID: "team-b")

        #expect(teamA.map(\.macDeviceID) == ["shared-mac"])
        #expect(teamB.map(\.macDeviceID) == ["shared-mac"])
        #expect(teamA.first?.displayName == "Team A Mac")
        #expect(teamB.first?.displayName == "Team B Mac")
        #expect(teamA.first?.routes.first?.id == "a")
        #expect(teamB.first?.routes.first?.id == "b")
        #expect(teamA.first?.customColor == "palette:1")
        #expect(teamB.first?.customColor == nil)
        #expect(try await store.activeMac(stackUserID: "user-1", teamID: "team-a")?.routes.first?.id == "a")
        #expect(try await store.activeMac(stackUserID: "user-1", teamID: "team-b")?.routes.first?.id == "b")
    }
}

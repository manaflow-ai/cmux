import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct IOSBuildScopedPairedMacStoreTests {
    @Test func buildScopeDecoratesComputerNamesIdempotently() throws {
        let scope = try #require(MobileIOSBuildScope("future-one"))

        #expect(scope.computerDisplayName("MacBook Pro") == "MacBook Pro (future-one)")
        #expect(scope.computerDisplayName("MacBook Pro (future-one)") == "MacBook Pro (future-one)")
    }

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

    @Test func scopesRowsByIOSBuildTag() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("feature")))
        let other = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("other")))

        try await feature.upsert(
            macDeviceID: "mac-a",
            displayName: "A",
            routes: [try route("10.0.0.1")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await other.upsert(
            macDeviceID: "mac-b",
            displayName: "B",
            routes: [try route("10.0.0.2")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        #expect(try await feature.loadAll(stackUserID: "user-1", teamID: "team-a").map(\.macDeviceID) == ["mac-a"])
        #expect(try await other.loadAll(stackUserID: "user-1", teamID: "team-a").map(\.macDeviceID) == ["mac-b"])
        #expect(try await feature.loadAll(stackUserID: "user-1", teamID: "team-a").first?.teamID == "team-a")
    }

    @Test func versionedScopeDoesNotRestoreLegacyScopedRows() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await inner.upsert(
            macDeviceID: "legacy-mac",
            displayName: "Legacy",
            routes: [try route("10.0.0.9")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a\u{1F}ios:ZmVhdHVyZQ",
            now: Date(timeIntervalSince1970: 1)
        )

        let current = IOSBuildScopedPairedMacStore(
            inner: inner,
            scope: try #require(MobileIOSBuildScope("feature"))
        )
        #expect(try await current.loadAll(stackUserID: "user-1", teamID: "team-a").isEmpty)
    }

    @Test func selectedTeamStillReadsTeamlessRowsInCurrentScope() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("feature")))
        let other = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("other")))

        try await feature.upsert(
            macDeviceID: "teamless",
            displayName: "Teamless",
            routes: [try route("10.0.0.1")],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await other.upsert(
            macDeviceID: "other-scope",
            displayName: "Other",
            routes: [try route("10.0.0.2")],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )

        let rows = try await feature.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.map(\.macDeviceID) == ["teamless"])
        #expect(rows.first?.teamID == nil)
    }

    @Test func selectedTeamUpsertClaimsTeamlessScopedRow() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("feature")))

        try await feature.upsert(
            macDeviceID: "mac-a",
            displayName: "A",
            routes: [try route("10.0.0.1")],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await feature.setCustomization(
            macDeviceID: "mac-a",
            customName: "Desk",
            customColor: "palette:2",
            customIcon: "desktopcomputer",
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )
        try await feature.upsert(
            macDeviceID: "mac-a",
            displayName: "A",
            routes: [try route("10.0.0.9")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 3)
        )

        let selectedRows = try await feature.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(selectedRows.map(\.macDeviceID) == ["mac-a"])
        #expect(selectedRows.first?.teamID == "team-a")
        #expect(selectedRows.first?.customName == "Desk")
        #expect(selectedRows.first?.customColor == "palette:2")
        #expect(selectedRows.first?.customIcon == "desktopcomputer")
        #expect(try await feature.loadAll(stackUserID: "user-1", teamID: nil).isEmpty)
    }

    @Test func selectedTeamActivationClearsTeamlessFallback() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("feature")))

        try await feature.upsert(
            macDeviceID: "teamless",
            displayName: "Teamless",
            routes: [try route("10.0.0.1")],
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await feature.upsert(
            macDeviceID: "team-row",
            displayName: "Team",
            routes: [try route("10.0.0.2")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        let rows = try await feature.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.filter(\.isActive).map(\.macDeviceID) == ["team-row"])
        #expect(rows.first { $0.macDeviceID == "teamless" }?.isActive == false)
    }

    @Test func removeAllOnlyDeletesCurrentBuildScope() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("feature")))
        let other = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("other")))

        try await feature.upsert(
            macDeviceID: "mac-a",
            displayName: "A",
            routes: [try route("10.0.0.1")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await other.upsert(
            macDeviceID: "mac-b",
            displayName: "B",
            routes: [try route("10.0.0.2")],
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        try await feature.removeAll()

        #expect(try await feature.loadAll(stackUserID: "user-1", teamID: "team-a").isEmpty)
        #expect(try await other.loadAll(stackUserID: "user-1", teamID: "team-a").map(\.macDeviceID) == ["mac-b"])
    }

    @Test func currentScopePrefersInstalledBundleSuffix() {
        #expect(MobileIOSBuildScope.current(infoDictionary: ["CMUXDevTag": "feat"], bundleIdentifier: "dev.cmux.ios.other")?.value == "other")
        #expect(MobileIOSBuildScope.current(infoDictionary: ["CMUXDevTag": ""], bundleIdentifier: "dev.cmux.ios.agent")?.value == "agent")
        #expect(MobileIOSBuildScope.current(infoDictionary: ["CMUXDevTag": ""], bundleIdentifier: "dev.cmux.ios") == nil)
        #expect(MobileIOSBuildScope("Feature Tag")?.serializedScope == "ios:v2:RmVhdHVyZSBUYWc")
    }

    @Test func authChannelResolvesPairedMacInstanceWithoutChangingIOSScope() throws {
        let scope = try #require(MobileIOSBuildScope("future-one"))

        #expect(scope.pairedMacInstanceTag(isDevelopmentAuthEnvironment: true) == "future-one")
        #expect(scope.pairedMacInstanceTag(isDevelopmentAuthEnvironment: false) == "default")
        #expect(scope.serializedScope == "ios:v2:ZnV0dXJlLW9uZQ")
    }
}

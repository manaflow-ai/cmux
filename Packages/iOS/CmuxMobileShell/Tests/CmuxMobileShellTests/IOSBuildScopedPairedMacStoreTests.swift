import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct IOSBuildScopedPairedMacStoreTests {
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

    @Test func currentScopeReadsInfoPlistThenBundleSuffix() {
        #expect(MobileIOSBuildScope.current(infoDictionary: ["CMUXDevTag": "feat"], bundleIdentifier: "dev.cmux.ios.other")?.value == "feat")
        #expect(MobileIOSBuildScope.current(infoDictionary: ["CMUXDevTag": ""], bundleIdentifier: "dev.cmux.ios.agent")?.value == "agent")
        #expect(MobileIOSBuildScope.current(infoDictionary: ["CMUXDevTag": ""], bundleIdentifier: "dev.cmux.ios") == nil)
    }
}

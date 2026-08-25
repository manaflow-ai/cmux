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

    private func irohRoute(_ endpointID: Character) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(endpointID: String(repeating: endpointID, count: 64)),
                pathHints: []
            )
        )
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
            instanceTag: "feature",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await other.upsert(
            macDeviceID: "mac-b",
            displayName: "B",
            routes: [try route("10.0.0.2")],
            instanceTag: "other",
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
            instanceTag: "feature",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await other.upsert(
            macDeviceID: "other-scope",
            displayName: "Other",
            routes: [try route("10.0.0.2")],
            instanceTag: "other",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )

        let rows = try await feature.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.map(\.macDeviceID) == ["teamless"])
        #expect(rows.first?.teamID == nil)
    }

    @Test func buildScopeKeepsSiblingTagsAndHidesMatchingLegacyPeer() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try #require(MobileIOSBuildScope("feature"))
        let feature = MobileMacBuildCompatibilityPolicy.development
            .scoping(IOSBuildScopedPairedMacStore(inner: inner, scope: scope))

        try await feature.upsert(
            macDeviceID: "mac-a",
            displayName: "Current",
            routes: [try irohRoute("a")],
            instanceTag: "feature",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 30)
        )
        try await inner.upsert(
            macDeviceID: "mac-a",
            displayName: "Other app instance",
            routes: [try irohRoute("b")],
            instanceTag: "other",
            markActive: false,
            stackUserID: "user-1",
            teamID: "\u{1F}\(scope.serializedScope)",
            now: Date(timeIntervalSince1970: 20)
        )
        try await inner.upsert(
            macDeviceID: "mac-a",
            displayName: "Legacy alias",
            routes: [try irohRoute("a")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "\u{1F}\(scope.serializedScope)",
            now: Date(timeIntervalSince1970: 10)
        )

        let rows = try await feature.loadAll(stackUserID: "user-1", teamID: "team-a")

        #expect(Set(rows.compactMap(\.instanceTag)) == ["feature", "other"])
    }

    @Test func compatibleSiblingTagsSurviveFullBuildScopeDecoratorRail() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scoped = IOSBuildScopedPairedMacStore(
            inner: inner,
            scope: try #require(MobileIOSBuildScope("phand1"))
        )
        let production = MobileMacBuildCompatibilityPolicy.development.scoping(scoped)

        for (index, tag) in ["phand1", "phand2", "phand3"].enumerated() {
            try await production.upsert(
                macDeviceID: "shared-mac",
                displayName: "Shared Mac (\(tag))",
                routes: [try irohRoute(Character(String(index + 1)))],
                instanceTag: tag,
                markActive: index == 0,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: Double(index + 1))
            )
        }

        let rows = try await production.loadAll(
            stackUserID: "user-1",
            teamID: "team-a"
        )
        #expect(rows.compactMap(\.instanceTag).sorted() == [
            "phand1", "phand2", "phand3",
        ])
    }

    @Test func newerTeamlessSiblingTagIsVisibleWithoutStealingActiveSelection() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try #require(MobileIOSBuildScope("feature"))
        let feature = MobileMacBuildCompatibilityPolicy.development
            .scoping(IOSBuildScopedPairedMacStore(inner: inner, scope: scope))
        try await feature.upsert(
            macDeviceID: "mac-a",
            displayName: "Selected",
            routes: [try route("10.0.0.1")],
            instanceTag: "feature",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await inner.upsert(
            macDeviceID: "mac-a",
            displayName: "Fallback",
            routes: [try route("10.0.0.2")],
            instanceTag: "feature-b",
            markActive: false,
            stackUserID: "user-1",
            teamID: "\u{1F}\(scope.serializedScope)",
            now: Date(timeIntervalSince1970: 2)
        )

        let rows = try await feature.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        )
        #expect(Set(rows.compactMap(\.instanceTag)) == ["feature", "feature-b"])
        let selected = try #require(rows.first { $0.instanceTag == "feature" })
        #expect(selected.teamID == "team-a")
        #expect(selected.routes == [try route("10.0.0.1")])
        #expect(selected.isActive)
        #expect(try await feature.activeMac(
            stackUserID: "user-1", teamID: "team-a"
        )?.instanceTag == "feature")
    }

    @Test func selectedTeamUpsertClaimsTeamlessScopedRow() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = IOSBuildScopedPairedMacStore(inner: inner, scope: try #require(MobileIOSBuildScope("feature")))

        try await feature.upsert(
            macDeviceID: "mac-a",
            displayName: "A",
            routes: [try route("10.0.0.1")],
            instanceTag: "feature",
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
            instanceTag: "feature",
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
            instanceTag: "feature",
            markActive: true,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await feature.upsert(
            macDeviceID: "team-row",
            displayName: "Team",
            routes: [try route("10.0.0.2")],
            instanceTag: "feature",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 2)
        )

        let rows = try await feature.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.filter(\.isActive).map(\.macDeviceID) == ["team-row"])
        #expect(rows.first { $0.macDeviceID == "teamless" }?.isActive == false)
    }

    @Test func conditionalRestoreCannotStealActiveTeamlessFallback() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = IOSBuildScopedPairedMacStore(
            inner: inner, scope: try #require(MobileIOSBuildScope("feature"))
        )
        try await feature.upsert(
            macDeviceID: "mac-b", displayName: "B", routes: [try route("10.0.0.2")],
            instanceTag: "feature", markActive: true, stackUserID: "user-1",
            teamID: nil, now: Date(timeIntervalSince1970: 20)
        )

        _ = try await feature.upsertIfNewer(
            macDeviceID: "mac-a", displayName: "A", routes: [try route("10.0.0.1")],
            instanceTag: "feature", customName: nil, customColor: nil,
            customIcon: nil, markActive: true, stackUserID: "user-1",
            teamID: "team-a", now: Date(timeIntervalSince1970: 10)
        )

        let rows = try await feature.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.first(where: { $0.macDeviceID == "mac-a" })?.isActive == false)
        #expect(rows.first(where: { $0.macDeviceID == "mac-b" })?.isActive == true)
    }

    @Test func conditionalRestorePreservesActiveFallbackWhileClaimingItsScope() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let feature = IOSBuildScopedPairedMacStore(
            inner: inner, scope: try #require(MobileIOSBuildScope("feature"))
        )
        try await feature.upsert(
            macDeviceID: "mac-a", displayName: "A", routes: [try route("10.0.0.1")],
            instanceTag: "feature", markActive: false, stackUserID: "user-1",
            teamID: nil, now: Date(timeIntervalSince1970: 1)
        )
        try await feature.setActive(
            macDeviceID: "mac-a", stackUserID: "user-1", teamID: nil
        )

        _ = try await feature.upsertIfNewer(
            macDeviceID: "mac-a", displayName: "A", routes: [try route("10.0.0.9")],
            instanceTag: "feature", customName: nil, customColor: nil,
            customIcon: nil, markActive: false, stackUserID: "user-1",
            teamID: "team-a", now: Date(timeIntervalSince1970: 10)
        )

        let rows = try await feature.loadAll(stackUserID: "user-1", teamID: "team-a")
        #expect(rows.count == 1)
        #expect(rows.first?.teamID == "team-a")
        #expect(rows.first?.isActive == true)
    }

    @Test func liveFallbackWriteWaitsForRestoreAndWinsAfterward() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try #require(MobileIOSBuildScope("feature"))
        let seedStore = IOSBuildScopedPairedMacStore(inner: inner, scope: scope)
        try await seedStore.upsert(
            macDeviceID: "mac-a", displayName: "A", routes: [try route("10.0.0.1")],
            instanceTag: "feature", markActive: true, stackUserID: "user-1",
            teamID: nil, now: Date(timeIntervalSince1970: 1)
        )
        let gatedInner = GatedUpsertStore(inner: inner)
        let feature = IOSBuildScopedPairedMacStore(inner: gatedInner, scope: scope)

        let restore = Task {
            try await feature.upsertIfNewer(
                macDeviceID: "mac-a", displayName: "Restored A",
                routes: [try route("10.0.0.9")], instanceTag: "feature",
                customName: nil, customColor: nil, customIcon: nil,
                markActive: true, stackUserID: "user-1", teamID: "team-a",
                now: Date(timeIntervalSince1970: 10)
            )
        }
        await gatedInner.waitUntilUpsertEntered()
        let liveWrite = Task {
            try await feature.upsert(
                macDeviceID: "mac-a", displayName: "Live B",
                routes: [try route("10.0.0.2")], instanceTag: "feature",
                markActive: true, stackUserID: "user-1", teamID: nil,
                now: Date(timeIntervalSince1970: 20)
            )
        }
        await gatedInner.release()
        _ = try await restore.value
        try await liveWrite.value

        let current = try #require(await feature.loadAll(
            stackUserID: "user-1", teamID: "team-a"
        ).first(where: { $0.macDeviceID == "mac-a" }))
        #expect(current.instanceTag == "feature")
        #expect(current.displayName == "Live B")
        #expect(current.routes.first?.endpoint == .hostPort(host: "10.0.0.2", port: 22))
        #expect(current.isActive)
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
            instanceTag: "feature",
            markActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await other.upsert(
            macDeviceID: "mac-b",
            displayName: "B",
            routes: [try route("10.0.0.2")],
            instanceTag: "other",
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

    /// Exact-scope removal must delete ONLY the requested team's row, never the
    /// team-less fallback in the same build scope, all the way down the dev-build
    /// store rail (`MobileMacCompatiblePairedMacStore` over
    /// `IOSBuildScopedPairedMacStore`).
    ///
    /// `remove` intentionally clears BOTH the team row and its team-less fallback
    /// (a Hide should drop every visible alias of a device). Forget targets one
    /// exact owner, so it must not use that broad `remove`. Before the fix,
    /// neither decorator overrode `removeExactScope`, so the protocol default
    /// forwarded it to `remove`: the compat layer's default called its own
    /// `remove`, which called the build-scope decorator's `remove`, which deletes
    /// the team-less fallback alongside the team row. That erased a still-valid
    /// team-less pairing when a co-located team pairing was forgotten.
    @Test func exactScopeRemovalThroughCompatLayerKeepsTeamlessBuildScopeFallback() async throws {
        let (inner, directory) = try makeInnerStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try #require(MobileIOSBuildScope("feature"))
        let scoped = IOSBuildScopedPairedMacStore(inner: inner, scope: scope)
        let stack = MobileMacBuildCompatibilityPolicy.development.scoping(scoped)

        // A team-scoped row for the device, written through the full rail.
        try await stack.upsert(
            macDeviceID: "mac-a", displayName: "Team", routes: [try route("10.0.0.1")],
            instanceTag: "feature", markActive: false, stackUserID: "user-1",
            teamID: "team-a", now: Date(timeIntervalSince1970: 2)
        )
        // A team-less fallback in the SAME build scope for the same device + tag,
        // seeded raw so the team upsert's claim path doesn't fold it in.
        try await inner.upsert(
            macDeviceID: "mac-a", displayName: "Fallback", routes: [try route("10.0.0.2")],
            instanceTag: "feature", markActive: false, stackUserID: "user-1",
            teamID: "\u{1F}\(scope.serializedScope)", now: Date(timeIntervalSince1970: 1)
        )

        let scopedTeam = "team-a\u{1F}\(scope.serializedScope)"
        let scopedTeamless = "\u{1F}\(scope.serializedScope)"
        let before = try await inner.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(before.contains { $0.macDeviceID == "mac-a" && $0.teamID == scopedTeam })
        #expect(before.contains { $0.macDeviceID == "mac-a" && $0.teamID == scopedTeamless })

        try await stack.removeExactScope(
            macDeviceID: "mac-a", instanceTag: "feature",
            stackUserID: "user-1", teamID: "team-a"
        )

        let after = try await inner.loadAll(stackUserID: "user-1", teamID: nil)
        // The exact team row is gone.
        #expect(!after.contains { $0.macDeviceID == "mac-a" && $0.teamID == scopedTeam })
        // The co-located team-less fallback survives an exact-scope team removal.
        #expect(after.contains { $0.macDeviceID == "mac-a" && $0.teamID == scopedTeamless })
    }

}

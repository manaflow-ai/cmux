import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// A store double whose cross-team enumeration fails, modeling a read error
/// during wildcard cleanup. Everything else forwards to the wrapped store.
private struct EnumerationFailingStore: MobilePairedMacStoring {
    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {}

    struct EnumerationError: Error {}
    let inner: any MobilePairedMacStoring

    func loadAllInstances(
        macDeviceID _: String,
        stackUserID _: String?
    ) async throws -> [MobilePairedMac] {
        throw EnumerationError()
    }

    func upsert(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.upsert(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertIfNewer(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, customName: String?, customColor: String?, customIcon: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertIfNewer(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, customName: customName, customColor: customColor, customIcon: customIcon, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertRoutesIfAuthorized(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], condition: MobilePairedMacRouteWriteCondition, markActive: Bool?, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertRoutesIfAuthorized(macDeviceID: macDeviceID, displayName: displayName, routes: routes, condition: condition, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(macDeviceID: String, customName: String?, customColor: String?, customIcon: String?, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.setCustomization(macDeviceID: macDeviceID, customName: customName, customColor: customColor, customIcon: customIcon, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func remove(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID)
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }
}

/// Regression coverage for the BREADTH of a forget.
///
/// A row with no instance tag cannot name which broker binding is its own, so
/// forgetting it revokes EVERY binding for the device (wildcard) — that side is
/// fixed. The local cleanup must match that breadth: deleting only the exact
/// nil-tag row leaves the device's tagged sibling rows saved locally while
/// their bindings were just revoked, so they linger as dead entries that
/// resurface in the computer list until the Mac happens to re-register. A
/// tag-known forget stays narrow on both sides; only the wildcard case widens.
@MainActor
@Suite struct MobileShellCompositeForgetWildcardBreadthTests {
    @Test func wildcardForgetDeletesEveryLocalRowOfTheDevice() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The same device paired twice: a tagged dev-build row and an untagged
        // row (tag unknown). Both owned by user-1, team-less. The TAGGED row is
        // seeded FIRST: a tagged upsert CLAIMS an existing untagged row of the
        // same device, but an untagged upsert never claims a tagged row, so this
        // order leaves two coexisting rows — the mixed state a legacy add after
        // a tagged pairing produces.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (feature)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: "feature",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: base,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { nil },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        // The nil-tag row cannot name its binding, so the revoke was the
        // device-wide wildcard (instanceTag nil = all tags).
        // Local cleanup must match the wildcard's breadth: EVERY row of the
        // device is gone, including the tagged sibling whose binding was just
        // revoked. Leaving it saved strands a dead entry in the computer list.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
    }

    /// A tag-known forget stays narrow: it revokes exactly its own binding and
    /// deletes exactly its own row, leaving the device's other rows alone.
    @Test func tagExactForgetLeavesSiblingRowsAlone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // Tagged row first, untagged second: same coexistence recipe as above.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (feature)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: "feature",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: base,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { nil },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: "feature")
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == "feature"
        })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        // Only the tagged row is gone; the untagged sibling survives.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" && $0.instanceTag == "feature" })
        #expect(remaining.contains { $0.macDeviceID == "mac-a" && $0.instanceTag == nil })
    }

    /// A wildcard forget's cleanup must be BATCHED: delete every row first,
    /// then refresh the paired list (and with it the backup restore) ONCE.
    /// Refreshing per deleted row re-runs the backup restore fetch for every
    /// sibling — a device can hold up to the discovery snapshot's 256 bindings,
    /// so per-row refreshes turn one forget into hundreds of sequential network
    /// round-trips while the row stays busy.
    @Test func wildcardForgetRefreshesOnceNotPerSibling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // Three tagged siblings plus one untagged row of the same device, seeded
        // raw so no upload traffic muddies the fetch counting. Tagged rows are
        // seeded FIRST: a tagged upsert CLAIMS an existing untagged row of the
        // same device, but an untagged upsert never claims a tagged row, so this
        // order leaves all four rows coexisting.
        for (index, tag) in ["one", "two", "three"].enumerated() {
            try await base.upsert(
                macDeviceID: "mac-a",
                displayName: "Desk Mac (\(tag))",
                routes: [try Self.route("100.82.214.11\(index + 3)")],
                instanceTag: tag,
                markActive: false,
                stackUserID: "user-1",
                teamID: nil,
                now: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 4)
        )
        let backup = FakeBackup()
        let backingUp = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { nil }
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: backingUp,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { nil },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })
        let fetchesBefore = await backup.fetches()

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        // Every row of the device is gone (breadth), and the whole cleanup
        // triggered at most ONE list refresh's backup restore, not one per row.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
        #expect(await backup.fetches() - fetchesBefore <= 1)
    }

    /// The wildcard revoke kills the device's bindings for the WHOLE account,
    /// across teams. Cleanup must match: a same-device row stored under another
    /// team just lost its binding too, and an offline Mac never re-registers,
    /// so leaving that row (and its backup) makes the supposedly forgotten
    /// computer reappear when the user switches teams or restores.
    @Test func wildcardForgetDeletesSameDeviceRowsInOtherTeams() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A tagged row in ANOTHER team, then the team-less untagged row the user
        // forgets. Tagged/teamed first so later upserts cannot claim it.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (feature)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: "feature",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-b",
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )
        // Realistic rail: the team-scoping decorator is what normally hides
        // other teams' rows from the composite, so the cross-team cleanup must
        // work through it. "team-a" is selected the whole time — the team-less
        // row is shown under it (legacy visibility) and forgotten from there,
        // while the device's team-b row is invisible to the display scope.
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: TeamScopedPairedMacStore(inner: base, teamIDProvider: { "team-a" }),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        // EVERY row of the device is gone, including the other team's: its
        // binding was revoked account-wide and an offline Mac cannot self-heal.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
    }

    /// A wildcard forget's backup tombstones must flush as ONE request per
    /// destination, not one request per deleted row. Each per-row flush is a
    /// network round-trip whose failure burns a full request timeout, and a
    /// device can carry up to the discovery snapshot's 256 bindings — per-row
    /// flushing turns one tap into minutes of sequential requests after the
    /// broker revoke loop already ran.
    @Test func wildcardForgetFlushesTombstonesInOneRequestPerDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // Three tagged siblings plus the untagged row, all in ONE team (their
        // own team is the verified destination), seeded raw. Tagged first so
        // the untagged upsert cannot be claimed.
        for (index, tag) in ["one", "two", "three"].enumerated() {
            try await base.upsert(
                macDeviceID: "mac-a",
                displayName: "Desk Mac (\(tag))",
                routes: [try Self.route("100.82.214.11\(index + 3)")],
                instanceTag: tag,
                markActive: false,
                stackUserID: "user-1",
                teamID: "team-a",
                now: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 4)
        )
        let backup = FakeBackup()
        let backingUp = BackingUpPairedMacStore(
            inner: base,
            backup: backup,
            teamIDProvider: { "team-a" }
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: backingUp,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        // Every row of the device is gone...
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
        // ...and their four tombstones traveled in ONE request to the one
        // destination, not one request per row.
        let deleteBatches = await backup.uploadBatches().filter { batch in
            batch.contains {
                switch $0 {
                case .delete, .deleteInstance: return true
                default: return false
                }
            }
        }
        #expect(deleteBatches.count == 1)
        #expect(deleteBatches.first?.count == 4)
    }

    /// A failed cross-team enumeration is a CLEANUP failure: the account-wide
    /// revoke already succeeded, so silently claiming success would leave
    /// sibling rows whose bindings are dead to reappear in another team or
    /// restore. The forget must report failure so the user can retry.
    @Test func wildcardForgetReportsFailureWhenSiblingEnumerationFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: EnumerationFailingStore(inner: base),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { nil },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(!ok)
    }

    /// A TAGGED forget's revoke is also account-wide for that (device, tag)
    /// binding, and the local store allows the same tagged pairing under
    /// several team scopes. Forgetting team A's row kills the binding team B's
    /// identical-tag row uses, so B's row must be cleaned too — while a row
    /// with a DIFFERENT tag keeps its own live binding and must survive.
    @Test func tagExactForgetDeletesSameTagRowsInOtherTeamsOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The same tagged pairing in two teams, plus a different-tag row.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (feature, team A)",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: "feature",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (feature, team B)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: "feature",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-b",
            now: Date(timeIntervalSince1970: 2)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (other)",
            routes: [try Self.route("100.82.214.114")],
            instanceTag: "other",
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 3)
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: TeamScopedPairedMacStore(inner: base, teamIDProvider: { "team-a" }),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: "feature")
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == "feature"
        })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        // The revoke stayed tag-exact.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        // Both teams' "feature" rows are gone: their shared binding is revoked.
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" && $0.instanceTag == "feature" })
        // The different-tag row keeps its live binding and survives.
        #expect(remaining.contains { $0.macDeviceID == "mac-a" && $0.instanceTag == "other" })
    }

    /// The wildcard revoke is TAG-BLIND on the broker: it kills bindings for
    /// every instance tag of the device, including tags this iOS build is not
    /// compatible with. The build-compatibility store forwards those rows from
    /// the cleanup enumeration, so its exact-scope delete must not silently
    /// no-op them: the tombstone still flushes and the forget reports success,
    /// leaving a local row whose binding is already revoked to resurface as a
    /// dead entry on a compatible build.
    @Test func wildcardForgetDeletesRowsWithBuildIncompatibleTags() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A row tagged for an incompatible distributed build plus the untagged row the
        // user forgets. Tagged first so the untagged upsert cannot claim it.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (Stable)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: "default",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )
        // Development rail: the Stable row is incompatible, visible to the
        // cleanup enumeration but historically
        // silently skipped by the compatibility guard on exact-scope deletes.
        let compatible = MobileMacBuildCompatibilityPolicy.development.scoping(base)
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: compatible,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { nil },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        // The wildcard revoke killed the Stable binding too, so its local row
        // must be gone — not silently skipped while the forget reports success.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
    }

    /// Hidden markers are stored per (user, team). A forget deletes rows across
    /// teams, so it must clear each deleted row's marker in THAT row's team
    /// scope, not only the display scope: a marker left in another team keeps a
    /// re-registering Mac unexpectedly hidden there, contradicting the forget
    /// confirmation that it will reappear on its next connect.
    @Test func forgetClearsHiddenMarkersInEachDeletedRowsOwnTeam() async throws {
        final class TeamBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            var value: String? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The same pairing saved under two teams.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team A)",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team B)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-b",
            now: Date(timeIntervalSince1970: 2)
        )
        let team = TeamBox()
        team.value = "team-a"
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: TeamScopedPairedMacStore(inner: base, teamIDProvider: { team.value }),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        // Hide the pairing in BOTH teams, so a per-(user, team) marker exists in
        // each scope.
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        team.value = "team-b"
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        // Forget from team A. The cleanup deletes BOTH teams' rows.
        team.value = "team-a"
        await store.loadPairedMacs()
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })
        let ok = await store.forgetHiddenComputer(hidden)
        #expect(ok)

        // The still-online Mac re-registers in team B before any rowless-marker
        // migration runs. The forget promised it would reappear on reconnect, so
        // team B's marker must be gone with team B's row.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team B)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-b",
            now: Date(timeIntervalSince1970: 3)
        )
        team.value = "team-b"
        await store.loadPairedMacs()
        #expect(store.pairedMacs.contains { $0.macDeviceID == "mac-a" })
        #expect(!store.hiddenComputers.contains { $0.macDeviceID == "mac-a" })
    }

    /// A PARTIALLY failed cleanup must keep the user's retry path. The batch
    /// delete deliberately attempts every row, so the primary row can be gone
    /// while a sibling's delete failed (`cleaned == false`, markers kept). The
    /// post-forget refresh must then be SKIPPED: its rowless-marker migration
    /// sees the deleted primary as a marker without a row and clears it, so the
    /// hidden entry the user would retry from disappears while the failed
    /// sibling — whose binding is already revoked — remains saved.
    @Test func partiallyFailedForgetKeepsTheHiddenRetryEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // A tagged sibling whose exact-scope delete will FAIL, plus the untagged
        // row the user forgets. Tagged first so the untagged upsert cannot claim it.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (bad)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: "bad",
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 2)
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: ExactScopeFailingStore(inner: base, failingInstanceTag: "bad"),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { nil },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })

        let ok = await store.forgetHiddenComputer(hidden)

        // The sibling's delete failed, so the forget reports failure...
        #expect(!ok)
        // ...and the hidden entry survives as the retry owner. Losing it here
        // strands the sibling row with its already-revoked binding.
        #expect(store.hiddenComputers.contains {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })
    }

    /// A PARTIALLY failed cleanup must still clear the markers of rows it DID
    /// delete. The batch deliberately attempts every row; a row deleted before
    /// the failure can never be re-enumerated on retry (`loadAllInstances`
    /// reads the local rows), so its per-(user, team) hidden marker would
    /// survive forever and keep the Mac unexpectedly hidden when it
    /// re-registers in that team. The failed row's marker stays as the retry
    /// owner.
    @Test func partiallyFailedForgetClearsMarkersOfDeletedSiblings() async throws {
        final class TeamBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            var value: String? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The same pairing in two teams, hidden in both. Team A's delete FAILS
        // (retry owner); team B's succeeds.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team A)",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team B)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-b",
            now: Date(timeIntervalSince1970: 2)
        )
        let team = TeamBox()
        team.value = "team-a"
        // Production shape: the batching store attempts EVERY row even when
        // one fails, so team B's row is deleted while team A's throws.
        let failing = ExactScopeFailingStore(
            inner: TeamScopedPairedMacStore(inner: base, teamIDProvider: { team.value }),
            failingInstanceTag: nil,
            failingTeamID: "team-a"
        )
        let backingUp = BackingUpPairedMacStore(
            inner: failing,
            backup: FakeBackup(),
            teamIDProvider: { team.value }
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: backingUp,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        team.value = "team-b"
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        team.value = "team-a"
        await store.loadPairedMacs()
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })

        let ok = await store.forgetHiddenComputer(hidden)

        // Team A's delete failed, so the forget reports failure and team A's
        // hidden entry survives as the retry owner.
        #expect(!ok)
        #expect(store.hiddenComputers.contains { $0.macDeviceID == "mac-a" })
        // Team B's row was deleted; its marker must be gone with it, so the
        // Mac re-registering in team B (through the production write seam) is
        // not unexpectedly hidden there.
        team.value = "team-b"
        try await backingUp.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team B)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: nil,
            now: Date(timeIntervalSince1970: 3)
        )
        await store.loadPairedMacs()
        #expect(store.pairedMacs.contains { $0.macDeviceID == "mac-a" })
        #expect(!store.hiddenComputers.contains { $0.macDeviceID == "mac-a" })
    }

    /// A FAILED sibling in another team must keep a durable retry entry. The
    /// displayed primary row is normally the only hidden one; when IT deletes
    /// but an undisplayed sibling's delete fails, the primary's marker turns
    /// rowless (the next load's migration clears it) and the sibling — whose
    /// binding was already revoked — resurfaces as a NORMAL computer in its
    /// team with no Hidden Computers entry left to retry from. The partial
    /// failure must record a marker for every surviving failed scope.
    @Test func failedUndisplayedSiblingGainsARetryMarker() async throws {
        final class TeamBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String?
            var value: String? {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        // The displayed primary in team A (its delete SUCCEEDS) and an
        // undisplayed sibling in team B (its delete FAILS).
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team A)",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            now: Date(timeIntervalSince1970: 1)
        )
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac (team B)",
            routes: [try Self.route("100.82.214.113")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-b",
            now: Date(timeIntervalSince1970: 2)
        )
        let team = TeamBox()
        team.value = "team-a"
        let failing = ExactScopeFailingStore(
            inner: TeamScopedPairedMacStore(inner: base, teamIDProvider: { team.value }),
            failingInstanceTag: nil,
            failingTeamID: "team-b"
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            // OFFLINE for the whole scenario: with the network up, the
            // account-wide parked intent finishes the sibling's cleanup on the
            // next restore anyway; offline, the marker is the only thing
            // standing between the user and a dead-binding ghost with no retry
            // entry.
            pairedMacStore: BackingUpPairedMacStore(
                inner: failing,
                backup: FakeBackup(failNextFetches: 99),
                teamIDProvider: { team.value }
            ),
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )
        // Hidden ONLY in team A — the ordinary single-team hide.
        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a", instanceTag: nil)
        let hidden = try #require(store.hiddenComputers.first {
            $0.macDeviceID == "mac-a" && $0.instanceTag == nil
        })

        let ok = await store.forgetHiddenComputer(hidden)
        #expect(!ok)

        // The next team-A load runs the rowless-marker migration over the
        // deleted primary; the surviving FAILED sibling in team B must still
        // have a hidden entry to retry from.
        await store.loadPairedMacs()
        team.value = "team-b"
        await store.loadPairedMacs()
        #expect(store.hiddenComputers.contains { $0.macDeviceID == "mac-a" })
        #expect(!store.pairedMacs.contains { $0.macDeviceID == "mac-a" })
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}

/// A store double whose exact-scope delete fails for one instance tag (or one
/// (tag, team) pair), so a batched wildcard cleanup partially succeeds.
/// Everything else forwards.
private struct ExactScopeFailingStore: MobilePairedMacStoring {
    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws {}

    struct ExactScopeError: Error {}
    let inner: any MobilePairedMacStoring
    let failingInstanceTag: String?
    let failingTeamID: String?
    let failsByTeam: Bool

    init(inner: any MobilePairedMacStoring, failingInstanceTag: String) {
        self.inner = inner
        self.failingInstanceTag = failingInstanceTag
        self.failingTeamID = nil
        self.failsByTeam = false
    }

    init(
        inner: any MobilePairedMacStoring,
        failingInstanceTag: String?,
        failingTeamID: String?
    ) {
        self.inner = inner
        self.failingInstanceTag = failingInstanceTag
        self.failingTeamID = failingTeamID
        self.failsByTeam = true
    }

    func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        let fails = failsByTeam
            ? (instanceTag == failingInstanceTag && teamID == failingTeamID)
            : (instanceTag == failingInstanceTag)
        if fails { throw ExactScopeError() }
        try await inner.removeExactScope(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    func upsert(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.upsert(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertIfNewer(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], instanceTag: String?, customName: String?, customColor: String?, customIcon: String?, markActive: Bool, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertIfNewer(macDeviceID: macDeviceID, displayName: displayName, routes: routes, instanceTag: instanceTag, customName: customName, customColor: customColor, customIcon: customIcon, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func upsertRoutesIfAuthorized(macDeviceID: String, displayName: String?, routes: [CmxAttachRoute], condition: MobilePairedMacRouteWriteCondition, markActive: Bool?, stackUserID: String?, teamID: String?, now: Date) async throws -> Bool {
        try await inner.upsertRoutesIfAuthorized(macDeviceID: macDeviceID, displayName: displayName, routes: routes, condition: condition, markActive: markActive, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAll(stackUserID: stackUserID, teamID: teamID)
    }

    func loadAllInstances(macDeviceID: String, stackUserID: String?) async throws -> [MobilePairedMac] {
        try await inner.loadAllInstances(macDeviceID: macDeviceID, stackUserID: stackUserID)
    }

    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
        try await inner.activeMac(stackUserID: stackUserID, teamID: teamID)
    }

    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.setActive(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func clearActive(stackUserID: String?, teamID: String?) async throws {
        try await inner.clearActive(stackUserID: stackUserID, teamID: teamID)
    }

    func setCustomization(macDeviceID: String, customName: String?, customColor: String?, customIcon: String?, stackUserID: String?, teamID: String?, now: Date) async throws {
        try await inner.setCustomization(macDeviceID: macDeviceID, customName: customName, customColor: customColor, customIcon: customIcon, stackUserID: stackUserID, teamID: teamID, now: now)
    }

    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, stackUserID: stackUserID, teamID: teamID)
    }

    func remove(macDeviceID: String, instanceTag: String?, stackUserID: String?, teamID: String?) async throws {
        try await inner.remove(macDeviceID: macDeviceID, instanceTag: instanceTag, stackUserID: stackUserID, teamID: teamID)
    }

    func removeAll() async throws {
        try await inner.removeAll()
    }
}

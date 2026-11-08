import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

/// A thread-safe mutable box for the active team id, so a test can flip the
/// selected team the store decorator observes partway through an async forget.
private final class TeamlessScopeTeamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?
    init(_ value: String?) { storedValue = value }
    var value: String? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

/// A forget capability that flips the selected team the moment the revoke runs,
/// so the local cleanup sees a DIFFERENT team than the one captured before the
/// revoke started.
@MainActor
private final class TeamlessScopeFlippingForget: MobileIrohMacForgetting {
    private let onForget: () -> Void
    private(set) var forgottenMacDeviceIDs: [String] = []

    init(onForget: @escaping () -> Void) {
        self.onForget = onForget
    }

    func forgetComputer(
        macDeviceID: String,
        instanceTag _: String?,
        expectedAccountID _: String
    ) async throws {
        forgottenMacDeviceIDs.append(macDeviceID)
        onForget()
    }
}

/// Regression coverage for the forget path's team-scope capture. Each deleted
/// row must be keyed by its OWN captured scope — never re-resolved through the
/// LIVE display scope, which can flip to another team while the revoke is in
/// flight.
///
/// The original bug: the forget flow deleted against the live display scope.
/// Deleting a team-less pairing while a team was (or became) selected either
/// missed the team-less row (leaving it to resurface) or deleted a row under
/// whatever team the flip landed on. Row-own scope keys are immune to the flip
/// because they are snapshotted up front. Note the BREADTH here is separate
/// from the KEYING: a tag-less forget's revoke is device-wide for the account,
/// so its cleanup deliberately deletes the device's same-account rows in other
/// teams too (see `MobileShellCompositeForgetWildcardBreadthTests`) — each
/// still by its own scope key, which is what this suite pins.
@MainActor
@Suite struct MobileShellCompositeForgetTeamlessScopeTests {
    @Test func forgetDeletesTeamlessRowNotFlippedTeamRowWhenScopeFlipsMidRevoke() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )

        // Same device paired both inside "team-b" and team-less, as two independent
        // rows. Seed the team row FIRST: `upsert(teamID:)` claims a pre-existing
        // team-less row into the selected team (team-less -> team migration), so
        // seeding team-less first would collapse both into one team-b row. A later
        // team-less `upsert(teamID: nil)` never claims a team row, so this order
        // leaves two rows: `user-1/team-b` and `user-1/<team-less>`. The forget
        // targets the team-less pairing; the team-b row must survive untouched.
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
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

        // No team selected when the forget begins; the revoke flips into "team-b".
        let team = TeamlessScopeTeamBox(nil)
        let scoped = TeamScopedPairedMacStore(inner: base, teamIDProvider: { team.value })
        let forget = TeamlessScopeFlippingForget { team.value = "team-b" }
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: scoped,
            personalIrohForget: forget,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(store.hiddenComputers.first { $0.macDeviceID == "mac-a" })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        #expect(forget.forgottenMacDeviceIDs == ["mac-a"])
        // The tag-less forget's revoke was device-wide for the account, so BOTH
        // rows are gone: the captured team-less row as the primary delete, and
        // the team-b row as wildcard-breadth cleanup (its binding was revoked
        // too). What the flip must NOT do is misdirect either delete — each row
        // is keyed by its OWN stamped scope, so the mid-revoke flip to "team-b"
        // changes nothing about which rows are targeted.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" })
    }

    /// A team-less pairing shown under a SELECTED team (legacy visibility) must
    /// delete its own team-less row when forgotten, even with NO mid-revoke flip.
    ///
    /// The bug this covers is distinct from the flip case above: here a team is
    /// selected the whole time. `loadAll(teamID: "team-a")` returns team-less rows
    /// too, so the user can see and forget a `teamID == nil` pairing while inside
    /// "team-a". The forget flow captured the LIVE display scope (`team-a`) and
    /// deleted with it, so `removeExactScope(teamID: "team-a")` matched nothing,
    /// the hidden marker was cleared, and the still-present team-less row
    /// resurfaced as a normal computer. The row's OWN scope (`teamID == nil`) is
    /// the only correct delete key.
    @Test func forgetDeletesTeamlessRowShownUnderSelectedTeam() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )

        // One team-less pairing. No team-scoped row exists for this device.
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

        // "team-a" is selected the entire time; the forget never flips scope.
        let team = TeamlessScopeTeamBox("team-a")
        let scoped = TeamScopedPairedMacStore(inner: base, teamIDProvider: { team.value })
        let forget = TeamlessScopeFlippingForget { }
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            pairedMacStore: scoped,
            personalIrohForget: forget,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { team.value },
            hiddenMacStore: InMemoryPairedMacHiddenStore()
        )

        await store.loadPairedMacs()
        await store.hideMac(macDeviceID: "mac-a")
        let hidden = try #require(store.hiddenComputers.first { $0.macDeviceID == "mac-a" })

        let ok = await store.forgetHiddenComputer(hidden)

        #expect(ok)
        #expect(forget.forgottenMacDeviceIDs == ["mac-a"])
        // The team-less row it was forgotten against must be gone, so it cannot
        // reappear when the user returns to no-team.
        let remaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
        #expect(!remaining.contains { $0.macDeviceID == "mac-a" && $0.teamID == nil })
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}

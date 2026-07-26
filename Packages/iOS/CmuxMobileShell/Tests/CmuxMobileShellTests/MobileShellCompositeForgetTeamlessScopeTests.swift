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

/// Regression coverage for the forget path's team-scope capture. The forget flow
/// snapshots its owner scope BEFORE an async network revoke, then deletes the
/// stored row. A team-less (nil-team) pairing must delete the team-less row it
/// was captured against, even if the user switches into a team while the revoke
/// is in flight.
///
/// The bug: local cleanup went through the team-scoping decorator's plain
/// `remove`, which substitutes a nil `teamID` with the CURRENTLY-selected team.
/// After a mid-revoke team switch that resolved the captured nil scope to the
/// freshly selected team, deleting that team's row instead and leaving the
/// forgotten team-less computer behind (it reappeared on returning to no-team).
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

        // Same device paired both team-less and inside "team-b". The forget targets
        // the team-less pairing; the team-b row must survive untouched.
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
        try await base.upsert(
            macDeviceID: "mac-a",
            displayName: "Desk Mac",
            routes: [try Self.route("100.82.214.112")],
            instanceTag: nil,
            markActive: false,
            stackUserID: "user-1",
            teamID: "team-b",
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
        // The captured team-less row is gone.
        let teamlessRemaining = try await base.loadAll(stackUserID: "user-1", teamID: nil)
            .map(\.macDeviceID)
        #expect(!teamlessRemaining.contains("mac-a"))
        // The team the scope flipped to mid-revoke keeps its row.
        let teamBRemaining = try await base.loadAll(stackUserID: "user-1", teamID: "team-b")
            .map(\.macDeviceID)
        #expect(teamBRemaining.contains("mac-a"))
    }

    private static func route(_ host: String, port: Int = 50922) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: "manual", kind: .tailscale, endpoint: .hostPort(host: host, port: port))
    }
}

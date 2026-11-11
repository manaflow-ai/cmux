import CMUXAuthCore
import CmuxNextAccounts
@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Observation
import Testing

/// The active team (``ActiveTeam``): one per signed-in account, the team every
/// team-scoped feature uses. A switch is saved for the account before it takes
/// effect, so it survives a relaunch (the account's saved selection wins at
/// restore) and a refused save keeps the current team.
@MainActor
@Suite
struct ActiveTeamTests {
    /// The account's memberships and saved selection, like `AuthCoordinator`.
    @MainActor @Observable
    final class Source: ActiveTeamSource {
        var isAuthenticated = true
        var availableTeams: [CMUXAuthTeam]
        /// The locally cached selection.
        var selectedTeamID: String?
        /// The account's saved selection (Stack Auth's selected team).
        private(set) var saved: [String?] = []
        var saveFailure: (any Error)?

        init(teams: [String], selected: String? = nil) {
            availableTeams = teams.map { CMUXAuthTeam(id: $0, displayName: $0.uppercased()) }
            selectedTeamID = selected
        }

        var resolvedTeamID: String? {
            if availableTeams.isEmpty { return selectedTeamID }
            if let selectedTeamID, availableTeams.contains(where: { $0.id == selectedTeamID }) { return selectedTeamID }
            return availableTeams.first?.id
        }

        /// Saves wait for ``releaseSaves()``.
        var holdSaves = false
        private var held: [CheckedContinuation<Void, Never>] = []
        var heldCount: Int { held.count }
        func releaseSaves() {
            held.forEach { $0.resume() }
            held = []
        }

        func selectTeam(id: String?) async throws {
            if let saveFailure { throw saveFailure }
            if holdSaves { await withCheckedContinuation { held.append($0) } }
            saved.append(id)
            selectedTeamID = id
        }

        /// The account's teams on the server; a re-read loads them. Nil: a read changes nothing.
        var serverTeams: [String]?
        private(set) var reads = 0
        /// Reads wait for ``releaseReads()``.
        var holdReads = false
        private var heldReads: [CheckedContinuation<Void, Never>] = []
        var heldReadCount: Int { heldReads.count }
        func releaseReads() {
            heldReads.forEach { $0.resume() }
            heldReads = []
        }

        func refreshTeams() async {
            reads += 1
            if holdReads { await withCheckedContinuation { heldReads.append($0) } }
            if let serverTeams { availableTeams = serverTeams.map { CMUXAuthTeam(id: $0, displayName: $0.uppercased()) } }
        }

        /// A relaunch: the account's saved selection replaces the local cache.
        func restore() { if let last = saved.last { selectedTeamID = last } }
    }

    struct SaveFailed: Error {}

    @Test func defaultsToTheFirstTeamWithoutASelection() {
        let active = ActiveTeam(source: Source(teams: ["a", "b"]))
        #expect(active.id == "a")
        #expect(active.team?.displayName == "A")
        #expect(active.canSwitch)
    }

    @Test func aSwitchIsSavedForTheAccountAndSurvivesARelaunch() async throws {
        let source = Source(teams: ["a", "b"], selected: "a")
        let active = ActiveTeam(source: source)
        try await active.select("b")
        #expect(source.saved == ["b"], "saved for the account, not only in this device's cache")
        #expect(active.id == "b")
        source.restore()
        #expect(active.id == "b")
    }

    @Test func aRefusedSaveKeepsTheCurrentTeam() async {
        let source = Source(teams: ["a", "b"], selected: "a")
        source.saveFailure = SaveFailed()
        let active = ActiveTeam(source: source)
        await #expect(throws: SaveFailed.self) { try await active.select("b") }
        #expect(active.id == "a")
        #expect(!active.isSwitching)
    }

    @Test func theLastSwitchWinsWhileOneIsSaving() async throws {
        // Rapid switches (the palette's chooser, the CLI, a second window): the newest choice is the
        // team cmux ends in, including a switch back to the team the first save is leaving.
        let source = Source(teams: ["a", "b", "c"], selected: "a")
        source.holdSaves = true
        let active = ActiveTeam(source: source)
        let first = Task { try await active.select("b") }
        for _ in 0..<100 where source.heldCount == 0 { await Task.yield() }
        #expect(source.heldCount == 1)
        #expect(active.isSwitching)
        try await active.select("c")
        try await active.select("a")
        #expect(active.isSwitching, "the first save is still in progress")
        source.holdSaves = false
        source.releaseSaves()
        try await first.value
        #expect(active.id == "a", "the newest choice wins")
        #expect(source.saved == ["b", "a"], "a choice replaced before its turn is never saved")
        #expect(!active.isSwitching)
    }

    @Test func refusesATeamTheAccountIsNotIn() async {
        let source = Source(teams: ["a", "b"], selected: "a")
        let active = ActiveTeam(source: source)
        await #expect(throws: ActiveTeam.Refusal.notMember) { try await active.select("z") }
        #expect(source.saved.isEmpty)
    }

    @Test func aManagedDeviceSeesAndUsesOnlyItsTeam() async {
        let source = Source(teams: ["a", "b"], selected: "a")
        let active = ActiveTeam(source: source)
        active.managedTeamID = "b"
        #expect(active.teams.map(\.id) == ["b"])
        #expect(active.id == "b")
        #expect(!active.canSwitch)
        await #expect(throws: ActiveTeam.Refusal.managed) { try await active.select("a") }
        active.managedTeamID = "missing"
        #expect(active.id == nil, "without the managed team there is none")
    }

    @Test func signedOutCannotSwitch() async {
        let source = Source(teams: ["a", "b"], selected: "a")
        source.isAuthenticated = false
        await #expect(throws: ActiveTeam.Refusal.signedOut) { try await ActiveTeam(source: source).select("b") }
        #expect(source.saved.isEmpty)
    }

    @Test func leavingTheActiveTeamFallsBackToAnother() {
        let source = Source(teams: ["a", "b"], selected: "b")
        let active = ActiveTeam(source: source)
        source.availableTeams.removeAll { $0.id == "b" }
        #expect(active.id == "a")
    }

    @Test func aSwitchIsObservable() async throws {
        let source = Source(teams: ["a", "b"], selected: "a")
        let active = ActiveTeam(source: source)
        let changed = Changed()
        withObservationTracking { _ = active.id } onChange: { changed.fire() }
        try await active.select("b")
        #expect(changed.fired)
    }

    nonisolated final class Changed: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        nonisolated var fired: Bool { lock.withLock { value } }
        nonisolated func fire() { lock.withLock { value = true } }
    }

    // MARK: Re-reading the teams (Leo, 2026-11-10: a team deleted on the web stayed selected)

    /// A clock the throttles read, moved by hand.
    @MainActor final class TestClock {
        var now = ContinuousClock.now
        func advance(_ by: Duration) { now = now.advanced(by: by) }
    }

    private func reading(_ source: Source) -> (ActiveTeam, TestClock) {
        let active = ActiveTeam(source: source), clock = TestClock()
        active.now = { clock.now }
        return (active, clock)
    }

    @Test func aTeamDeletedOnTheWebFallsBackWhenCmuxComesToTheFront() async {
        let source = Source(teams: ["a", "b"], selected: "b")
        let (active, _) = reading(source)
        let changed = Changed()
        withObservationTracking { _ = active.id } onChange: { changed.fire() }
        source.serverTeams = ["a"] // "b" deleted on the web
        await active.refreshIfStale()
        #expect(source.reads == 1)
        #expect(active.id == "a", "the selection the account no longer has falls back to the first team")
        #expect(changed.fired, "the team change reaches what follows the active team (the composer's chip)")
    }

    @Test func comingToTheFrontReReadsAtMostOnceAMinute() async {
        let source = Source(teams: ["a", "b"], selected: "a")
        let (active, clock) = reading(source)
        await active.refreshIfStale()
        clock.advance(.seconds(30))
        await active.refreshIfStale()
        #expect(source.reads == 1)
        clock.advance(.seconds(31))
        await active.refreshIfStale()
        #expect(source.reads == 2)
    }

    @Test func asksWhileAReadIsInFlightJoinIt() async {
        let source = Source(teams: ["a", "b"], selected: "a")
        source.holdReads = true
        let (active, _) = reading(source)
        let first = Task { await active.refresh() }
        for _ in 0..<100 where source.heldReadCount == 0 { await Task.yield() }
        let second = Task { await active.refreshIfStale() }
        let third = Task { await active.teamRefused("a") }
        for _ in 0..<100 { await Task.yield() }
        source.releaseReads()
        await first.value; await second.value; await third.value
        #expect(source.reads == 1)
    }

    @Test func aRefusalForTheActiveTeamReReadsOnceAndNeverLoops() async {
        let source = Source(teams: ["a", "b"], selected: "b")
        let (active, clock) = reading(source)
        await active.refreshIfStale() // a read a moment ago does not hold back a refusal's
        source.serverTeams = ["a", "b"] // still listed: the refusal stands, the team stays
        await active.teamRefused("b")
        #expect(source.reads == 2)
        #expect(active.id == "b")
        for _ in 0..<5 { await active.teamRefused("b") } // a caller retrying
        #expect(source.reads == 2, "one re-read per refused team a minute")
        await active.teamRefused("a") // not the active team
        #expect(source.reads == 2)
        clock.advance(.seconds(61))
        source.serverTeams = ["a"] // now gone
        await active.teamRefused("b")
        #expect(source.reads == 3)
        #expect(active.id == "a", "a refused team that is gone is not kept as the selection")
    }

    @Test func signedOutNeverReReads() async {
        let source = Source(teams: ["a"], selected: "a")
        source.isAuthenticated = false
        let (active, _) = reading(source)
        await active.refreshIfStale()
        await active.teamRefused("a")
        #expect(source.reads == 0)
    }

    // MARK: Settings > Accounts

    @Test func accountsPageListsTheTeamsWithTheActiveOneChecked() async throws {
        let services = MockAccountsServices()
        let model = AccountsModel(services: services)
        let teams = try #require(model.pageState.teams)
        #expect(teams.options.map(\.id) == ["team-personal", "team-acme"])
        #expect(teams.options.map(\.active) == [true, false])
        #expect(!teams.disabled)
        let action = try #require(AccountsPageAction(action: "selectTeam", provider: nil, account: nil, secret: nil, team: "team-acme"))
        await model.perform(action)
        #expect(services.activeTeam?.id == "team-acme")
        #expect(model.pageState.teams?.options.map(\.active) == [false, true])
    }

    @Test func accountsPageTeamsAreOffWhenManagedAndHiddenWhenSignedOut() throws {
        let services = MockAccountsServices()
        services.activeTeam?.managedTeamID = "team-personal"
        let model = AccountsModel(services: services)
        let teams = try #require(model.pageState.teams)
        #expect(teams.options.map(\.id) == ["team-personal"])
        #expect(teams.disabled)
        #expect(teams.note != nil)
        services.isSignedInToCmux = false
        #expect(model.pageState.teams == nil)
    }

    @Test func aFailedSwitchShowsOnThePage() async throws {
        let services = MockAccountsServices()
        services.teamFailure = SaveFailed()
        let model = AccountsModel(services: services)
        await model.selectTeam("team-acme")
        #expect(model.pageState.teams?.error != nil)
        #expect(model.pageState.teams?.options.map(\.active) == [true, false])
    }

    @Test func selectTeamNeedsATeam() {
        #expect(AccountsPageAction(action: "selectTeam", provider: nil, account: nil, secret: nil, team: nil) == nil)
        #expect(AccountsPageAction(action: "selectTeam", provider: nil, account: nil, secret: nil, team: "") == nil)
    }

    // MARK: coderouter.* over the socket (AppControl.passthrough)

    @Test func callsActOnlyInTheActiveTeam() {
        #expect(ActiveTeam.refusal(requesting: nil, active: "a", managed: nil) == nil)
        #expect(ActiveTeam.refusal(requesting: " ", active: "a", managed: nil) == nil)
        #expect(ActiveTeam.refusal(requesting: "a", active: "a", managed: nil) == nil)
        #expect(ActiveTeam.refusal(requesting: "b", active: "a", managed: nil) == .notActive)
        #expect(ActiveTeam.refusal(requesting: "b", active: nil, managed: nil) == .notActive)
        #expect(ActiveTeam.refusal(requesting: nil, active: "a", managed: "m") == .managed)
        #expect(ActiveTeam.refusal(requesting: "a", active: "m", managed: "m") == .managed)
        #expect(ActiveTeam.refusal(requesting: "m", active: "m", managed: "m") == nil)
    }
}

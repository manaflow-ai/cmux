import Foundation
import Testing
@testable import CmuxMobileModel

@Suite struct TeamListStateTests {
    let teams = [AppStore.AccountTeam(id: "t1", name: "One"), AppStore.AccountTeam(id: "t2", name: "Two")]

    @Test func startsLoadingAndAnEmptyPublishIsNotAnAnswer() {
        var state = TeamListState()
        #expect(state.phase == .loading)
        // The coordinator's initial empty list must not read as "no teams".
        state.published([])
        #expect(state.phase == .loading)
        #expect(!state.isLoaded)
    }

    @Test func publishedOrFetchedTeamsLoad() {
        var state = TeamListState()
        state.published(teams)
        #expect(state == TeamListState(phase: .loaded, teams: teams))
        var fetched = TeamListState()
        fetched.fetched([])
        // A fetch that answers with nothing is a real "no teams".
        #expect(fetched == TeamListState(phase: .loaded, teams: []))
    }

    @Test func failureRetriesAndNeverHidesALoadedList() {
        var state = TeamListState()
        state.failed("offline")
        #expect(state.phase == .failed("offline"))
        state.retry()
        #expect(state.phase == .loading)
        state.fetched(teams)
        state.failed("offline again")
        #expect(state == TeamListState(phase: .loaded, teams: teams))
        // Retry is only for a failure.
        state.retry()
        #expect(state.phase == .loaded)
        state.reset()
        #expect(state == TeamListState())
    }
}

@MainActor @Suite struct DiscoveryTests {
    func store(active: String = "a", macs: [String: [MacDevice]] = [:]) -> AppStore {
        let teams = ["a", "b", "c"].map { Team(id: $0, name: $0.uppercased(), macs: macs[$0] ?? []) }
        return AppStore(teams: teams, activeTeamID: active, workspaces: [], feed: [])
    }

    @Test func mergeShowsEachMacInItsTeamAndKeepsOtherMembersMacs() {
        let teammate = MacDevice(id: "x", name: "Teammate", isOnline: true)
        let s = store(macs: ["a": [teammate, MacDevice(id: "m1", name: "Old", isOnline: false)]])
        // m1 moved from a to b; m2 is new in c.
        s.mergeDiscoveredMacs([
            DiscoveredMac(id: "m1", name: "Studio", isOnline: true, teamID: "b"),
            DiscoveredMac(id: "m2", name: "Air", isOnline: false, teamID: "c"),
            DiscoveredMac(id: "m3", name: "Elsewhere", isOnline: true, teamID: "left-team"),
        ])
        #expect(s.teams[0].macs == [teammate])
        #expect(s.teams[1].macs == [MacDevice(id: "m1", name: "Studio", isOnline: true)])
        #expect(s.teams[2].macs == [MacDevice(id: "m2", name: "Air", isOnline: false)])
    }

    @Test func personalSpaceJoinsWhenAMacLivesThere() {
        let s = store()
        let personal = AppStore.AccountTeam(id: "personal-u", name: "Personal")
        s.mergeDiscoveredMacs([DiscoveredMac(id: "m", name: "Mini", isOnline: true, teamID: "b")], personal: personal)
        #expect(!s.teams.contains { $0.id == "personal-u" })
        s.mergeDiscoveredMacs([DiscoveredMac(id: "m", name: "Mini", isOnline: true, teamID: "personal-u")], personal: personal)
        #expect(s.teams.last?.id == "personal-u")
        #expect(s.teams.last?.macs.map(\.id) == ["m"])
        #expect(s.teams[1].macs.isEmpty)
    }

    @Test func followsAnOnlineMacElsewhereWhileWaiting() {
        let s = store()
        let found = [DiscoveredMac(id: "m", name: "Studio", isOnline: true, teamID: "c")]
        s.mergeDiscoveredMacs(found)
        // First look: the active team has no Mac, the account's Mac is online in c.
        #expect(s.teamToFollow(found, previouslyOnline: nil)?.id == "c")
        // Still waiting on later looks too (setup's "Waiting for your Mac").
        #expect(s.teamToFollow(found, previouslyOnline: [found[0].placement])?.id == "c")
        // An offline Mac is nothing to follow.
        let offline = [DiscoveredMac(id: "m", name: "Studio", isOnline: false, teamID: "c")]
        #expect(s.teamToFollow(offline, previouslyOnline: nil) == nil)
    }

    @Test func staysWhenTheActiveTeamHasAnOnlineMac() {
        let s = store(macs: ["a": [MacDevice(id: "here", name: "Here", isOnline: true)]])
        let found = [DiscoveredMac(id: "m", name: "Studio", isOnline: true, teamID: "b")]
        s.mergeDiscoveredMacs(found)
        #expect(s.teamToFollow(found, previouslyOnline: nil) == nil)
    }

    @Test func aPickedEmptyTeamStaysUntilAMacComesOnlineElsewhere() {
        let s = store()
        let found = [DiscoveredMac(id: "m", name: "Studio", isOnline: true, teamID: "b")]
        s.mergeDiscoveredMacs(found)
        // The user picked team a in the sidebar; m was already online: stay.
        #expect(s.teamToFollow(found, previouslyOnline: [found[0].placement], pinnedTeamID: "a") == nil)
        // A Mac that just came online still moves the phone.
        let more = found + [DiscoveredMac(id: "n", name: "Air", isOnline: true, teamID: "c")]
        s.mergeDiscoveredMacs(more)
        #expect(s.teamToFollow(more, previouslyOnline: [found[0].placement], pinnedTeamID: "a")?.id == "c")
    }

    @Test func offlineMacsInTheActiveTeamOnlyMoveOnAnArrival() {
        let s = store(macs: ["a": [MacDevice(id: "sleepy", name: "Sleepy", isOnline: false)]])
        let found = [
            DiscoveredMac(id: "sleepy", name: "Sleepy", isOnline: false, teamID: "a"),
            DiscoveredMac(id: "m", name: "Studio", isOnline: true, teamID: "b"),
        ]
        s.mergeDiscoveredMacs(found)
        #expect(s.teamToFollow(found, previouslyOnline: [found[1].placement]) == nil)
        #expect(s.teamToFollow(found, previouslyOnline: [])?.id == "b")
    }

    @Test func aMacThatMovesTeamsWhileOnlineIsFollowed() {
        // The phone followed m to b; then m's Mac re-registers into c, staying online.
        let s = store(active: "b", macs: ["b": [MacDevice(id: "old", name: "Old", isOnline: false)]])
        let before = DiscoveredMac(id: "m", name: "Studio", isOnline: true, teamID: "b")
        let after = DiscoveredMac(id: "m", name: "Studio", isOnline: true, teamID: "c")
        s.mergeDiscoveredMacs([after])
        #expect(s.teams[1].macs.map(\.id) == ["old"])
        #expect(s.teamToFollow([after], previouslyOnline: [before.placement])?.id == "c")
    }

    @Test func emptyStateOffersTheTeamWithAMac() {
        let s = store(macs: ["b": [MacDevice(id: "o", name: "Off", isOnline: false)], "c": [MacDevice(id: "on", name: "On", isOnline: true)]])
        let offer = s.teamWithMacsElsewhere()
        #expect(offer?.team.id == "c")
        #expect(offer?.mac.name == "On")
        #expect(store().teamWithMacsElsewhere() == nil)
    }

    /// The account-wide look keeps each Mac's machine id (and says the caller owns
    /// it), so two builds on one Mac stay one listed Mac after it, and an older
    /// Worker's look (no machine id) keeps the one the team list had.
    @Test func discoveryKeepsTheMachineID() {
        let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
        let s = AppStore(teams: [Team(id: "b", name: "B", macs: [])], activeTeamID: "b", workspaces: [], feed: [], tabMemory: .inMemory())
        s.mergeDiscoveredMacs([
            DiscoveredMac(id: "m1", name: "Mini", isOnline: true, teamID: "b", ownerUserID: "me", machineID: machine),
            DiscoveredMac(id: "m2", name: "Mini", isOnline: true, teamID: "b", ownerUserID: "me", machineID: machine),
        ])
        #expect(MacRoster(s.activeTeam?.macs ?? []).visible.map(\.id) == ["m1"])
        s.mergeDiscoveredMacs([
            DiscoveredMac(id: "m1", name: "Mini", isOnline: true, teamID: "b"),
            DiscoveredMac(id: "m2", name: "Mini", isOnline: true, teamID: "b"),
        ])
        #expect(s.activeTeam?.macs.map(\.machineID) == [machine, machine])
        #expect(MacRoster(s.activeTeam?.macs ?? []).visible.map(\.id) == ["m1"])
    }
}

@MainActor @Suite struct SignOutResetTests {
    @Test func signOutForgetsTheAccountButKeepsDevicePreferences() throws {
        let suite = "cmuxMobile.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = ["cmuxMobile.lastTeamID", "cmuxMobile.setupComplete", "cmuxMobile.teamAppearance.t1", "cmuxMobile.live.mac.t1",
                       "cmuxMobile.workspaces.recentDirectories.m1", "cmuxMobile.workspaces.newMac", "cmuxMobile.lastTabByWorkspace", "cmuxMobile.auth.selectedTeam"]
        let device = ["cmuxMobile.settings.terminalFontSize", "cmuxMobile.workspaces.sort", "cmuxMobile.dev.relayOnly", "cmuxMobile.settings.appearance"]
        for key in account + device { defaults.set("x", forKey: key) }

        let store = AppStore.mock(tabMemory: TabMemory(defaults: defaults))
        store.accountMacCount = 2
        store.macLinkStatus = ["m": "Connected"]
        store.macLinkDiagnostics = ["m": "private diagnostic"]
        store.resetForSignOut(defaults: defaults)

        #expect(store.teams.isEmpty && store.activeTeamID.isEmpty && store.workspaces.isEmpty)
        #expect(store.accountMacCount == nil && store.macLinkStatus.isEmpty)
        #expect(store.macLinkDiagnostics.isEmpty)
        #expect(store.teamDataState == .loading)
        for key in account { #expect(defaults.object(forKey: key) == nil, "\(key) survived sign-out") }
        for key in device { #expect(defaults.string(forKey: key) == "x", "\(key) was dropped") }
    }

    @Test func aNewAccountStartsWithItsTeamsLoading() {
        var teams = TeamListState()
        teams.fetched([AppStore.AccountTeam(id: "t1", name: "One")])
        teams.reset()
        #expect(teams == TeamListState())
    }
}

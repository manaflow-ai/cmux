import Foundation
import Testing
@testable import CmuxMobileModel

/// Settings: the Devices count and page read one list (design loop item 1),
/// and the small copy decisions behind the Settings rows.
@Suite struct SettingsRowsTests {
    private func mac(_ id: String, _ name: String = "Mac", online: Bool? = false) -> SettingsDevice {
        SettingsDevice(ids: [id], kind: .mac, name: name, online: online, lastSeenAt: nil, isThisDevice: false, receivesNotifications: false)
    }

    private func phone(_ id: String) -> SettingsDevice {
        SettingsDevice(ids: [id], kind: .phone, name: "iPhone", online: nil, lastSeenAt: nil, isThisDevice: false, receivesNotifications: true)
    }

    @Test func rootCountIsThePageMacRows() {
        // The account has 13 Macs; the active team has 2. The root shows the page's count.
        let service = (1...13).map { mac("m\($0)") } + [phone("p1")]
        let live = [MacDevice(id: "m1", name: "Mac", isOnline: true), MacDevice(id: "m2", name: "Mac", isOnline: false)]
        let rows = SettingsDeviceRows.macs(service: service, hasService: true, liveMacs: live)
        #expect(rows?.count == 13)
        #expect(SettingsDeviceRows.rootValue(service: service, hasService: true, liveMacs: live) == "13")
        #expect(SettingsDeviceRows.phones(service: service).count == 1)
    }

    @Test func notLoadedShowsNoValue() {
        let live = [MacDevice(id: "m1", name: "Mac", isOnline: true)]
        #expect(SettingsDeviceRows.macs(service: nil, hasService: true, liveMacs: live) == nil)
        #expect(SettingsDeviceRows.rootValue(service: nil, hasService: true, liveMacs: live) == nil)
    }

    @Test func emptyLoadedListCountsZero() {
        #expect(SettingsDeviceRows.rootValue(service: [phone("p")], hasService: true, liveMacs: []) == "0")
    }

    @Test func liveTeamsLayPresenceOverTheServiceList() {
        let seen = Date(timeIntervalSince1970: 1000)
        let rows = SettingsDeviceRows.macs(service: [mac("m1", online: false)], hasService: true,
                                           liveMacs: [MacDevice(id: "m1", name: "Mac", isOnline: true, lastSeenAt: seen)])
        #expect(rows?.first?.online == true)
        #expect(rows?.first?.lastSeenAt == seen)
    }

    /// Settings still lists every build, and says which rows are another build of a Mac Workspaces lists once.
    @Test func otherBuildsOfOneMacAreMarked() {
        let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
        var nightly = mac("3eb7", "MacBook Pro", online: true)
        nightly.machineID = machine
        var old = mac("39c6", "MacBook Pro", online: false)
        old.machineID = machine
        var sameName = mac("aaaa", "MacBook Pro", online: false)
        sameName.machineID = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
        let unknown = mac("bbbb", "MacBook Pro", online: false)
        let rows = SettingsDeviceRows.macs(service: [old, nightly, sameName, unknown], hasService: true, liveMacs: []) ?? []
        #expect(rows.count == 4)
        #expect(SettingsDeviceRows.otherBuilds(rows) == ["39c6"])
    }

    /// Builds of one computer in two teams are each listed by their team: neither is marked.
    @Test func buildsInTwoTeamsAreNotMarked() {
        let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
        var inTeam = mac("a", "Mini", online: true)
        inTeam.machineID = machine
        inTeam.teamID = "t"
        var inPersonal = mac("b", "Mini", online: false)
        inPersonal.machineID = machine
        inPersonal.teamID = "personal-me"
        #expect(SettingsDeviceRows.otherBuilds([inTeam, inPersonal]).isEmpty)
    }

    @Test func withoutAServiceEveryKnownMacOnce() {
        // A Mac in two teams is one row; the count matches the rows.
        let live = [MacDevice(id: "a", name: "A", isOnline: true), MacDevice(id: "b", name: "B", isOnline: false),
                    MacDevice(id: "a", name: "A", isOnline: true)]
        #expect(SettingsDeviceRows.macs(service: nil, hasService: false, liveMacs: live)?.map(\.id) == ["a", "b"])
        #expect(SettingsDeviceRows.rootValue(service: nil, hasService: false, liveMacs: live) == "2")
    }

    @Test func sizingSharesAccountDevicesBeforeDiscoveryAndKeepsTeamMacsWhenTheyArrive() {
        var kept = mac("kept", "Kept build", online: false)
        kept.machineID = "computer"
        let directory = [kept, mac("remote"), phone("iphone")]
        let cold = SettingsDeviceRows.sizingMacs(teams: [], activeTeamID: "team", service: directory, accountID: "me")
        #expect(cold.map(\.id) == ["kept", "remote"])
        let live = Team(id: "team", name: "Studio", macs: [
            MacDevice(id: "current", name: "Live build", isOnline: true, ownerUserID: "me", machineID: "computer"),
            MacDevice(id: "colleague", name: "Colleague's Mac", isOnline: true, ownerUserID: "other")
        ])
        let refreshed = SettingsDeviceRows.sizingMacs(teams: [live], activeTeamID: "team", service: directory, accountID: "me")
        #expect(refreshed.map(\.id) == ["current", "colleague", "remote"])
    }

    @MainActor @Test func sizingKeepsPeersOnlyWhileTheirTeamIsVisibleAndUntilItAnswersAgain() {
        let store = LastKnownListStore(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { store.removeAll() }
        let cache = store.list(accountID: "owner", screen: "terminal-sizing-peers")
        let first = TerminalSizingPeers(cache: cache)
        let a = Team(id: "a", name: "A", macs: [])
        let b = Team(id: "b", name: "B", macs: [])
        let peer = MacDevice(id: "peer", name: "Peer", isOnline: false, ownerUserID: "another")
        let mine = MacDevice(id: "mine", name: "Mine", isOnline: true, ownerUserID: "owner")
        first.replace(teamID: "a", devices: [peer, mine], accountID: "owner")
        let reopened = TerminalSizingPeers(cache: cache)
        #expect(reopened.visible(in: [a, b]) == [peer])
        #expect(reopened.visible(in: [b]).isEmpty)
        reopened.replace(teamID: "a", devices: [], accountID: "owner")
        #expect(TerminalSizingPeers(cache: cache).visible(in: [a, b]).isEmpty)
    }

    @Test func notificationValues() {
        #expect(NotificationPermission.on.rootValue(push: true) == "On")
        #expect(NotificationPermission.on.rootValue(push: false) == "Chief only")
        #expect(NotificationPermission.off.rootValue(push: false) == "Off")
        #expect(NotificationPermission.notDetermined.rootValue(push: false) == "Not set")
    }

    @Test func signInDetailSkipsTheAccountEmail() {
        let method = SignInMethod.emailCode("aziz@example.com")
        #expect(method.detail(accountEmail: "Aziz@Example.com") == nil)
        #expect(method.detail(accountEmail: "other@example.com") == "aziz@example.com")
        #expect(method.detail(accountEmail: nil) == "aziz@example.com")
        #expect(SignInMethod.google.detail(accountEmail: "a@b.c") == nil)
    }

    @Test func sameNameTagReadsTheSameEverywhere() {
        let names = MacNameDisambiguation([(id: "8c41e0d2-3f2a", name: "Aziz's MacBook Pro"), (id: "5b97a6f1-91c7", name: "Aziz's MacBook Pro"),
                                           (id: "solo", name: "Studio")])
        #expect(names.tag(for: "5b97a6f1-91c7") == "91C7")
        #expect(names.displayName(id: "5b97a6f1-91c7", name: "Aziz's MacBook Pro") == "Aziz's MacBook Pro 91C7")
        #expect(names.displayName(id: "solo", name: "Studio") == "Studio")
        #expect(names.added(for: "5b97a6f1-91c7", addedAt: nil) == nil)
        #expect(names.added(for: "solo", addedAt: Date()) == nil)
        #expect(names.added(for: "5b97a6f1-91c7", addedAt: Date())?.hasPrefix("Added ") == true)
    }

    #if DEBUG
    @Test func mockSwitchFollowsTheEnvironment() {
        #expect(DeveloperOptions.mockSwitch(stored: false, environment: ["CMUX_MOBILE_MOCK_AUTH": "1"]) == (true, true))
        #expect(DeveloperOptions.mockSwitch(stored: true, environment: [:]) == (true, false))
        #expect(DeveloperOptions.mockSwitch(stored: false, environment: [:]) == (false, false))
    }
    #endif
}

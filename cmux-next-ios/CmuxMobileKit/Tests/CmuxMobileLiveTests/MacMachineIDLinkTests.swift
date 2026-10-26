import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

#if os(iOS)
/// Two cmux builds on one Mac register two devices with one machine id
/// (PROTOCOL.md "Devices"). The phone lists and links that Mac once; two Macs
/// that only share a name stay two Macs, each linked.
@MainActor
@Suite(.serialized) struct MacMachineIDLinkTests {
    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"
    let teamID = "t-machine-\(UUID().uuidString.prefix(8))"

    func coordinator(store: AppStore, dialer: PerMacDialer, macs: [MacDevice]) -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-machine-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        let saved = Date(timeIntervalSince1970: 1_000)
        snapshots.save(LiveSnapshot(
            teamID: teamID, teamName: "One", macs: macs, linkedMacID: macs.first?.id,
            workspaces: Dictionary(uniqueKeysWithValues: macs.map { ($0.id, .init(workspaces: [], savedAt: saved)) })
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: dialer,
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    func settle(_ done: () -> Bool) async {
        for _ in 0..<3000 where !done() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func drain() async {
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func twoBuildsOnOneMacAreLinkedOnce() async {
        let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
        let macs = [
            MacDevice(id: "m1", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: machine),
            MacDevice(id: "m2", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: machine),
        ]
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer, macs: macs)
        defer { live.stop() }
        live.showing(macIDs: nil)
        await settle { store.macConnection["m1"] == .connected }
        await drain()
        #expect(store.macConnection["m1"] == .connected)
        #expect(dialer.dialCount("m2") == 0)
        #expect(MacRoster(store.activeTeam?.macs ?? []).visible.map(\.id) == ["m1"])
    }

    /// A Feed answer or notification of the other build names it: its link opens
    /// (the ask is answered on that build), and the focus stays on the listed one.
    @Test func theOtherBuildLinksWhenSomethingNamesIt() async {
        let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
        let macs = [
            MacDevice(id: "m1", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: machine),
            MacDevice(id: "m2", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: machine),
        ]
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer, macs: macs)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        live.touch("m2")
        await settle { store.macConnection["m2"] == .connected }
        #expect(store.macConnection["m2"] == .connected)
        #expect(live.focusedMacID == "m1")
    }

    /// Workspaces and the Feed show every listed Mac (`showing(nil)`): the other build
    /// named once closes after the idle window instead of staying linked.
    @Test func theOtherBuildIdlesOutWhileWorkspacesShows() async {
        let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
        let macs = [
            MacDevice(id: "m1", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: machine),
            MacDevice(id: "m2", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: machine),
        ]
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer, macs: macs)
        defer { live.stop() }
        live.linkPolicy = MacLinkPolicy(idleAfter: .milliseconds(200))
        live.showing(macIDs: nil)
        await settle { store.macConnection["m1"] == .connected }
        live.touch("m2")
        await settle { store.macConnection["m2"] == .connected }
        #expect(store.macConnection["m2"] == .connected)
        live.showing(macIDs: nil)
        await settle { store.macConnection["m2"] == nil }
        #expect(store.macConnection["m2"] == nil)
        #expect(store.macConnection["m1"] == .connected)
    }

    @Test func sameNamedMacsOnTwoComputersAreBothLinked() async {
        let macs = [
            MacDevice(id: "m1", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"),
            MacDevice(id: "m2", name: "cmux mini", isOnline: true, ownerUserID: userID, machineID: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"),
        ]
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let dialer = PerMacDialer()
        let live = coordinator(store: store, dialer: dialer, macs: macs)
        defer { live.stop() }
        live.showing(macIDs: nil)
        await settle { store.macConnection["m1"] == .connected && store.macConnection["m2"] == .connected }
        #expect(store.macConnection["m1"] == .connected)
        #expect(store.macConnection["m2"] == .connected)
        #expect(MacRoster(store.activeTeam?.macs ?? []).visible.map(\.id) == ["m1", "m2"])
    }

    /// The service's Mac list decodes the machine id the Worker sends (added 2026-10-21), and an older Worker's list has none.
    @Test func theMacListCarriesTheMachineID() throws {
        let json = #"{"deviceId":"m1","name":"Mini","online":true,"machineId":"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"}"#
        let mac = try JSONDecoder().decode(LiveAPI.Mac.self, from: Data(json.utf8))
        #expect(mac.machineId == "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1")
        let older = try JSONDecoder().decode(LiveAPI.Mac.self, from: Data(#"{"deviceId":"m1","name":"Mini","online":true}"#.utf8))
        #expect(older.machineId == nil)
    }
}
#endif

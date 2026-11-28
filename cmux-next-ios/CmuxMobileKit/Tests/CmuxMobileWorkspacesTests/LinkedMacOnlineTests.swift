import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// A Mac this phone holds a live link to is up on every screen, whatever the cmux service's
/// presence says (Aziz, 2026-11-26: "im also getting this in several screens despite my mac
/// being connected (ik because gui works)"). The service's presence alone stays in
/// `listedOnline` for the link machine.
@MainActor @Suite struct LinkedMacOnlineTests {
    let now = Date(timeIntervalSince1970: 2_000)

    func store(listedOnline: Bool) -> AppStore {
        let store = AppStore(
            teams: [Team(id: "t1", name: "One", macs: [MacDevice(id: "m1", name: "Studio", isOnline: listedOnline)])],
            activeTeamID: "t1",
            workspaces: [Workspace(id: "w1", macID: "m1", title: "w1", directory: "~", tabs: [], lastActivityAt: now)],
            feed: [],
            tabMemory: .inMemory([:])
        )
        store.tracksMacData = true
        return store
    }

    func mac(_ store: AppStore) throws -> MacDevice {
        try #require(store.activeTeam?.macs.first)
    }

    @Test func aLiveLinkIsOnlineThoughPresenceSaysOffline() throws {
        let store = store(listedOnline: false)
        #expect(try !mac(store).isOnline)
        store.macConnection["m1"] = .connected
        let linked = try mac(store)
        #expect(linked.isOnline)
        #expect(!linked.listedOnline)
        // The Workspaces list: no "Your Macs are offline" panel and no offline fold.
        let inbox = WorkspaceInbox(scope: .all, macs: store.activeTeam?.macs ?? [], workspaces: store.workspaces)
        #expect(!inbox.allAsleep)
        #expect(inbox.folds.isEmpty)
        #expect(inbox.recent.map(\.id) == ["w1"])
        // The Mac's own page: never "Studio is offline".
        let empty = MacEmptyState.resolve(isOnline: linked.isOnline, list: .live, connection: .connected,
                                          tracksLive: true, reach: .linkTarget, canCreate: true)
        #expect(empty != .offline)
        #expect(store.macReachability(linked) == .connected)
    }

    @Test func presenceCopiedBackFromTheStoreStaysTheServices() throws {
        let store = store(listedOnline: false)
        store.macConnection["m1"] = .connected
        // The coordinator rebuilds a team's list from the store's own copies on each presence
        // frame: the link's mark must not turn into the service's word.
        store.setMacs(store.activeTeam?.macs ?? [], teamID: "t1")
        #expect(try !mac(store).listedOnline)
        store.macConnection["m1"] = .connecting
        #expect(try !mac(store).isOnline)
    }

    @Test func presenceFramesKeepTheLinksMark() throws {
        let store = store(listedOnline: true)
        store.macConnection["m1"] = .connected
        // The service flaps the Mac offline while the link is up (a signaling reset).
        store.setMacs([MacDevice(id: "m1", name: "Studio", isOnline: false)], teamID: "t1")
        #expect(try mac(store).isOnline)
        store.macConnection = [:]
        #expect(try !mac(store).isOnline)
    }

    @Test func snapshotsKeepTheServicesPresenceUnderItsOldKey() throws {
        var mac = MacDevice(id: "m1", name: "Studio", isOnline: false)
        mac.linked = true
        let data = try JSONEncoder().encode(mac)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["isOnline"] as? Bool == false)
        #expect(object["linked"] == nil)
        let old = Data(#"{"id":"m1","name":"Studio","isOnline":true}"#.utf8)
        let decoded = try JSONDecoder().decode(MacDevice.self, from: old)
        #expect(decoded.listedOnline && decoded.isOnline && !decoded.linked)
    }
}

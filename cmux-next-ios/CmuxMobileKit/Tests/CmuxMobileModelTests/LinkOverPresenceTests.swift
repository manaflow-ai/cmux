import Foundation
import Testing
@testable import CmuxMobileModel

/// A Mac this phone's link is connected to is online on every screen, whatever the
/// service's presence heartbeat says (Aziz, 2026-11-26: "im also getting this in several
/// screens despite my mac being connected (ik because gui works)").
@MainActor
@Suite struct LinkOverPresenceTests {
    let seen = Date(timeIntervalSince1970: 1_000)

    func store(_ macs: [MacDevice]) -> AppStore {
        let store = AppStore(teams: [Team(id: "t", name: "T")], activeTeamID: "t", workspaces: [], feed: [])
        store.tracksMacData = true
        store.setMacs(macs, teamID: "t")
        return store
    }

    func mac(_ store: AppStore, _ id: String = "m") -> MacDevice? {
        store.activeTeam?.macs.first { $0.id == id }
    }

    @Test func aConnectedLinkWinsOverAStalePresence() {
        let store = store([MacDevice(id: "m", name: "Mac", isOnline: false, lastSeenAt: seen)])
        #expect(mac(store)?.isOnline == false)
        store.macConnection["m"] = .connected
        #expect(mac(store)?.isOnline == true)
        // A presence frame still saying offline does not flip it while the link is up.
        store.setMacs([MacDevice(id: "m", name: "Mac", isOnline: false, lastSeenAt: seen)], teamID: "t")
        #expect(mac(store)?.isOnline == true)
        let line = MacStatusLine.make(mac: mac(store)!, connection: .connected, live: true, presence: "Last seen")
        #expect(line.dot == .connected)
    }

    @Test func presenceIsBackOnceTheLinkDrops() {
        let store = store([MacDevice(id: "m", name: "Mac", isOnline: false, lastSeenAt: seen)])
        store.macConnection["m"] = .connected
        store.macConnection["m"] = .connecting
        #expect(mac(store)?.isOnline == false)
    }

    @Test func aCallerWritingBackTheShownListKeepsTheRawPresence() {
        let store = store([MacDevice(id: "m", name: "Mac", isOnline: false, lastSeenAt: seen),
                           MacDevice(id: "o", name: "Other", isOnline: true)])
        store.macConnection["m"] = .connected
        // As `applyPresence` does: read the shown list, edit another Mac, write it all back.
        var shown = store.activeTeam!.macs
        shown[1].name = "Renamed"
        store.setMacs(shown, teamID: "t")
        store.macConnection["m"] = nil
        #expect(mac(store)?.isOnline == false)
        #expect(mac(store, "o")?.name == "Renamed")
    }

    @Test func aLiveListClearsTheNotAnsweringFailure() {
        let store = store([MacDevice(id: "m", name: "Mac", isOnline: true)])
        // The workspaces deadline passed on a slow first load.
        store.handleMacData(.failed("Offline"), macID: "m")
        store.macFailure["m"] = .serviceDown
        store.macConnection["m"] = .connected
        store.handleMacData(.received(count: 3), macID: "m")
        #expect(store.macFailure["m"] == nil)
        #expect(MacReachability.resolve(mac: mac(store)!, connection: .connected, failure: store.macFailure["m"], live: true) == .connected)
    }

    @Test func aLiveListLeavesOtherFailuresAlone() {
        let store = store([MacDevice(id: "m", name: "Mac", isOnline: true)])
        store.macFailure["m"] = .authRequired
        store.handleMacData(.received(count: 1), macID: "m")
        #expect(store.macFailure["m"] == .authRequired)
    }
}

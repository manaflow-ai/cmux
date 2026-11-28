import Foundation
import Testing
@testable import CmuxMobileModel

/// A Mac whose workspaces list came back is answering, so a "cmux not answering" left by a
/// slow first load's deadline goes (Aziz, 2026-11-26: "im also getting this in several
/// screens despite my mac being connected (ik because gui works)").
@MainActor
@Suite struct LiveListClearsServiceDownTests {
    func store() -> AppStore {
        let store = AppStore(teams: [Team(id: "t", name: "T")], activeTeamID: "t", workspaces: [], feed: [])
        store.tracksMacData = true
        store.setMacs([MacDevice(id: "m", name: "Mac", isOnline: true)], teamID: "t")
        return store
    }

    @Test func aLiveListClearsTheNotAnsweringFailure() {
        let store = store()
        // The workspaces deadline passed on a slow first load.
        store.handleMacData(.failed("Offline"), macID: "m")
        store.macFailure["m"] = .serviceDown
        store.macConnection["m"] = .connected
        store.handleMacData(.received(count: 3), macID: "m")
        #expect(store.macFailure["m"] == nil)
        let mac = store.activeTeam!.macs[0]
        #expect(MacReachability.resolve(mac: mac, connection: .connected, failure: store.macFailure["m"], live: true) == .connected)
    }

    @Test func aLiveListLeavesOtherFailuresAlone() {
        let store = store()
        store.macFailure["m"] = .authRequired
        store.handleMacData(.received(count: 1), macID: "m")
        #expect(store.macFailure["m"] == .authRequired)
    }
}

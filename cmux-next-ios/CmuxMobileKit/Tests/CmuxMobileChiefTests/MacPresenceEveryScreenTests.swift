#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileChief

/// Every screen reads one answer to "is this Mac there" (``AppStore/macPresence(_:)``), so none
/// says the Mac is offline while this phone's link to it is up, and all agree when it is gone.
/// Leo, relaying Aziz (2026-11-28, ask-02dd2cc9ee): "im also getting this in several screens
/// despite my mac being connected (ik because gui works)".
@MainActor @Suite struct MacPresenceEveryScreenTests {
    func store(listedOnline: Bool) -> AppStore {
        let store = AppStore(
            teams: [Team(id: "t1", name: "One", macs: [MacDevice(id: "m1", name: "Studio", isOnline: listedOnline)])],
            activeTeamID: "t1", workspaces: [], feed: [], tabMemory: .inMemory([:]))
        store.tracksMacData = true
        return store
    }

    /// What each screen would say about the Mac, all read from the store's one answer.
    struct Screens {
        var homeSaysOffline: Bool
        var homeSaysProblem: Bool
        var chiefBarSaysOffline: Bool
        var chiefSettingsSaysNotConnected: Bool
        var macViewSaysOffline: Bool
    }

    func walk(_ store: AppStore) throws -> Screens {
        let presence = store.macPresence("m1")
        let home = HomeConnectionStatus.make(presence: presence, failed: false, retrying: false, macName: "Studio")
        let session = ChiefSession(backend: ChiefOfflineBackend(reason: "x"))
        defer { session.store.stop() }
        session.macID = "m1"
        session.macPresenceSource = { store.macPresence($0) }
        let mac = try #require(store.activeTeam?.macs.first)
        let reach = store.macReachability(mac)
        return Screens(
            homeSaysOffline: home?.kind == .macOffline,
            homeSaysProblem: home != nil,
            chiefBarSaysOffline: ChiefSources.awayReason(session.macPresence) == ChiefSources.macOfflineReason,
            chiefSettingsSaysNotConnected: !session.macPresence.isUp,
            macViewSaysOffline: { if case .offline = reach { true } else { false } }())
    }

    /// The case Aziz hit: the service's presence says offline, the link is up.
    @Test(arguments: [false, true])
    func aLinkedMacIsUpOnEveryScreen(listedOnline: Bool) throws {
        let store = store(listedOnline: listedOnline)
        store.macConnection["m1"] = .connected
        #expect(store.macPresence("m1") == .up)
        let screens = try walk(store)
        #expect(!screens.homeSaysOffline)
        #expect(!screens.homeSaysProblem)
        #expect(!screens.chiefBarSaysOffline)
        #expect(!screens.chiefSettingsSaysNotConnected)
        #expect(!screens.macViewSaysOffline)
    }

    /// The Mac really gone (no link, the service says offline): every screen agrees.
    @Test func aGoneMacIsOfflineOnEveryScreen() throws {
        let store = store(listedOnline: false)
        #expect(store.macPresence("m1") == .down(listedOnline: false))
        let screens = try walk(store)
        #expect(screens.homeSaysOffline)
        #expect(screens.chiefBarSaysOffline)
        #expect(screens.chiefSettingsSaysNotConnected)
        #expect(screens.macViewSaysOffline)
    }

    /// The link down but the service says online: a reach problem, never "offline".
    @Test func anUnreachableOnlineMacIsNotOffline() throws {
        let store = store(listedOnline: true)
        let screens = try walk(store)
        #expect(store.macPresence("m1") == .down(listedOnline: true))
        #expect(!screens.homeSaysOffline)
        #expect(screens.homeSaysProblem)
    }

    /// Chief failing on a connected Mac blames Chief, not the Mac.
    @Test func chiefDownOnAConnectedMacDoesNotSayTheMacIsOffline() {
        #expect(ChiefSources.awayReason(.up) == ChiefSources.chiefNotAnsweringReason)
        #expect(!ChiefSources.awayReason(.up).localizedCaseInsensitiveContains("offline"))
        #expect(ChiefSources.awayReason(.down(listedOnline: false)) == ChiefSources.macOfflineReason)
    }

    /// Mock mode and no Mac named: nothing is said.
    @Test func untrackedSaysNothing() {
        let store = store(listedOnline: false)
        store.tracksMacData = false
        #expect(store.macPresence("m1") == .untracked)
        #expect(HomeConnectionStatus.make(presence: .untracked, failed: false, retrying: false, macName: nil) == nil)
        store.tracksMacData = true
        #expect(store.macPresence(nil) == .untracked)
    }
}
#endif

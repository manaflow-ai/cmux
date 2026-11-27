import Foundation
import Testing
@testable import CmuxMobileModel

/// Aziz, 2026-11-26: "im also getting this in several screens despite my mac being connected (ik
/// because gui works)". Presence is the service's signaling socket; a signaling reset says offline
/// for a moment while this phone's link to the Mac is fine (LinkMachine keeps that link). Every
/// screen reads `MacDevice.isOnline`, so a Mac this phone is linked to reads online there, and the
/// raw presence stays in `listedOnline` for the link and the reachability rule.
@MainActor
@Suite struct LinkedMacOnlineTests {
    func store(online: Bool) -> AppStore {
        AppStore(teams: [Team(id: "t", name: "T", macs: [MacDevice(id: "m1", name: "Mac", isOnline: online)])],
                 activeTeamID: "t", workspaces: [], feed: [], tabMemory: .inMemory())
    }

    func mac(_ store: AppStore) -> MacDevice { store.teams[0].macs[0] }

    @Test func aLinkedMacReadsOnlineWhilePresenceSaysOffline() {
        let store = store(online: false)
        #expect(!mac(store).isOnline)
        store.macConnection["m1"] = .connected
        #expect(mac(store).isOnline)
        #expect(!mac(store).listedOnline)
        #expect(store.activeTeam?.macs.contains(where: \.isOnline) == true)
    }

    @Test func aPresenceWriteWhileLinkedStaysOnline() {
        let store = store(online: true)
        store.macConnection["m1"] = .connected
        // The signaling socket resets: presence writes the Mac offline, the link is still up.
        store.setMacs([MacDevice(id: "m1", name: "Mac", isOnline: false)], teamID: "t")
        #expect(mac(store).isOnline)
        #expect(!mac(store).listedOnline)
    }

    @Test func theLinkDroppingFallsBackToPresence() {
        let store = store(online: false)
        store.macConnection["m1"] = .connected
        store.macConnection["m1"] = .failed("Offline")
        #expect(!mac(store).isOnline)
        store.macConnection["m1"] = .connected
        store.macConnection["m1"] = nil
        #expect(!mac(store).isOnline)
    }

    @Test func aDialUnderWayIsNotALink() {
        let store = store(online: false)
        store.macConnection["m1"] = .connecting
        #expect(!mac(store).isOnline)
    }

    @Test func reachabilityReadsPresenceNotTheLinkOverlay() {
        var linked = MacDevice(id: "m1", name: "Mac", isOnline: false)
        linked.linkUp = true
        // The link failed: what the service lists decides, not the stale overlay.
        let reach = MacReachability.resolve(mac: linked, connection: .failed("x"), failure: .hostUnreachable, live: false)
        #expect(reach == .offline(lastSeenAt: nil))
    }

    @Test func theLinkIsNeverCached() throws {
        var linked = MacDevice(id: "m1", name: "Mac", isOnline: false)
        linked.linkUp = true
        let data = try JSONEncoder().encode(linked)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"isOnline\":false"))
        #expect(!json.contains("linkUp"))
        let back = try JSONDecoder().decode(MacDevice.self, from: data)
        #expect(!back.isOnline && !back.linkUp)
    }
}

import Foundation
import Testing
@testable import CmuxMobileModel

/// The honest data states: nothing says "No workspaces" (or any empty
/// state) until the Mac itself answered.
@Suite struct MacDataMachineTests {
    let saved = Date(timeIntervalSince1970: 1_000)

    @Test func noCacheConnectingIsLoadingNeverEmpty() {
        var machine = MacDataMachine()
        #expect(machine.phase == .idle)
        machine.handle(.connecting)
        #expect(machine.phase == .loading)
        #expect(!machine.phase.isEmpty)
        machine.handle(.received(count: 0))
        #expect(machine.phase == .empty)
        #expect(machine.phase.isEmpty)
    }

    @Test func cacheShowsWhileConnectingThenGoesLive() {
        var machine = MacDataMachine()
        machine.handle(.restored(count: 3, savedAt: saved))
        machine.handle(.connecting)
        #expect(machine.phase == .cached(.connecting))
        #expect(machine.phase.isStale)
        machine.handle(.received(count: 4))
        #expect(machine.phase == .live)
        #expect(!machine.phase.isStale)
    }

    @Test func aCachedEmptyListIsNotTheEmptyState() {
        var machine = MacDataMachine()
        machine.handle(.restored(count: 0, savedAt: saved))
        machine.handle(.connecting)
        #expect(machine.phase == .cached(.connecting))
        #expect(!machine.phase.isEmpty)
    }

    @Test func failureWithoutCacheIsFailedAndRetriesKeepTheReason() {
        var machine = MacDataMachine()
        machine.handle(.connecting)
        machine.handle(.failed("the Mac didn't answer in time"))
        #expect(machine.phase == .failed("the Mac didn't answer in time"))
        // The retry does not flash back to the skeleton.
        machine.handle(.connecting)
        #expect(machine.phase == .failed("the Mac didn't answer in time"))
        machine.handle(.received(count: 1))
        #expect(machine.phase == .live)
        // Once live, a later dial starts from connecting again.
        machine.handle(.disconnected(at: saved))
        machine.handle(.connecting)
        #expect(machine.phase == .cached(.connecting))
    }

    @Test func failureWithCacheKeepsTheRowsDimmed() {
        var machine = MacDataMachine()
        machine.handle(.restored(count: 2, savedAt: saved))
        machine.handle(.failed("refused"))
        #expect(machine.phase == .cached(.failed("refused")))
    }

    @Test func liveDataBecomesCacheWhenTheLinkDropsOrTheMacGoesOffline() {
        var machine = MacDataMachine()
        machine.handle(.received(count: 2))
        machine.handle(.disconnected(at: saved))
        #expect(machine.phase == .cached(.idle))
        #expect(machine.source == .cache(savedAt: saved))
        machine.handle(.received(count: 2))
        machine.handle(.offline)
        #expect(machine.phase == .cached(.offline))
        var fresh = MacDataMachine()
        fresh.handle(.offline)
        #expect(fresh.phase == .offline)
    }

    @Test func aRestoreNeverOverwritesLiveData() {
        var machine = MacDataMachine()
        machine.handle(.received(count: 5))
        machine.handle(.restored(count: 1, savedAt: saved))
        #expect(machine.phase == .live)
        #expect(machine.count == 5)
    }

    @MainActor @Test func storePhaseInMockAndLiveMode() {
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        // Mock mode: what is there is live.
        #expect(store.macDataPhase("m") == .empty)
        store.tracksMacData = true
        #expect(store.macDataPhase("m") == .idle)
        store.handleMacData(.connecting, macID: "m")
        #expect(store.macDataPhase("m") == .loading)
    }
}

@Suite struct MacStatusLineTests {
    let online = MacDevice(id: "m", name: "Studio", isOnline: true)

    @Test func greenOnlyWhenThisPhoneIsConnected() {
        #expect(MacStatusLine.make(mac: online, connection: .connected, live: true, presence: "Online")
            == MacStatusLine(dot: .connected, text: "Online"))
        #expect(MacStatusLine.make(mac: online, connection: .connecting, live: true, presence: "Online")
            == MacStatusLine(dot: .connecting, text: "Online · Connecting…"))
        #expect(MacStatusLine.make(mac: online, connection: .failed("x"), live: true, presence: "Online")
            == MacStatusLine(dot: .failed, text: "Online · Can't connect"))
        #expect(MacStatusLine.make(mac: online, connection: nil, live: true, presence: "Online").dot == .connecting)
    }

    @Test func offlineAndMockFollowPresence() {
        var offline = online
        offline.isOnline = false
        #expect(MacStatusLine.make(mac: offline, connection: .connected, live: true, presence: "Last seen 2h ago")
            == MacStatusLine(dot: .offline, text: "Last seen 2h ago"))
        #expect(MacStatusLine.make(mac: online, connection: nil, live: false, presence: "Online")
            == MacStatusLine(dot: .connected, text: "Online"))
    }
}

@Suite struct LiveSnapshotStoreTests {
    @Test func roundTripsPerAccountAndForgetsOnRemoveAll() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-snapshot-\(UUID().uuidString)")
        let store = LiveSnapshotStore(directory: directory)
        let workspace = Workspace(id: "w", macID: "m", title: "cmux-mobile-demo", directory: "~/x",
                                  tabs: [WorkspaceTab(id: "s1", kind: .agent, title: "Claude", harness: "claude")],
                                  lastActivityAt: Date(timeIntervalSince1970: 5))
        let snapshot = LiveSnapshot(teamID: "personal-u", teamName: "Personal",
                                    macs: [MacDevice(id: "m", name: "Studio", isOnline: true)], linkedMacID: "m",
                                    workspaces: ["m": .init(workspaces: [workspace], savedAt: Date(timeIntervalSince1970: 9))])
        store.save(snapshot, accountID: "user/1")
        store.flush()
        #expect(store.load(accountID: "user/1") == snapshot)
        #expect(store.load(accountID: "user-2") == nil)
        store.removeAll()
        store.flush()
        #expect(store.load(accountID: "user/1") == nil)
    }
}

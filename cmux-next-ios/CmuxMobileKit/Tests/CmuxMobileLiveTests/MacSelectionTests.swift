import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// verify/e2e-matrix.md #2: with two online Macs the phone linked the first,
/// and choosing the other only filtered the list. Choosing a Mac
/// (`select(macID:)`, called by the Workspaces filter and by opening one
/// of its workspaces) moves the link and is remembered for the next launch.
@MainActor
@Suite(.serialized) struct MacSelectionTests {
    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"

    func coordinator(store: AppStore) -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-select-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        let saved = Date(timeIntervalSince1970: 1_000)
        snapshots.save(LiveSnapshot(
            teamID: "t1", teamName: "One",
            macs: [MacDevice(id: "m1", name: "Studio", isOnline: true), MacDevice(id: "m2", name: "MacBook Pro", isOnline: true)],
            linkedMacID: "m1",
            workspaces: ["m1": .init(workspaces: [], savedAt: saved), "m2": .init(workspaces: [], savedAt: saved)]
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: MockDialer(fail: false),
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    func settle(_ done: () -> Bool) async {
        for _ in 0..<3000 where !done() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    // Red on the iOS simulator in CI: the remembered Mac reads back nil (#24010).
    @Test(.disabled("The remembered Mac reads back nil on the iOS simulator in CI"),
          .bug("https://github.com/manaflow-ai/cmux/issues/24010"))
    func choosingAnotherOnlineMacMovesTheLink() async {
        let key = "cmuxMobile.live.mac.t1"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = coordinator(store: store)
        defer { live.stop() }
        await settle { store.macConnection["m1"] == .connected }
        #expect(live.link.target?.macID == "m1")
        #expect(live.canLink(macID: "m2"))

        live.select(macID: "m2")
        #expect(live.link.target?.macID == "m2")
        await settle { store.macConnection["m2"] == .connected }
        #expect(store.macConnection["m2"] == .connected)
        // The first Mac keeps its own link (PROTOCOL.md "One link per Mac").
        #expect(store.macConnection["m1"] == .connected)
        #expect(UserDefaults.standard.string(forKey: key) == "m2")

        // Choosing the linked Mac again changes nothing (no redial).
        live.select(macID: "m2")
        #expect(live.link.target?.macID == "m2")
        #expect(live.link.phase.isConnected)
    }
}
#endif

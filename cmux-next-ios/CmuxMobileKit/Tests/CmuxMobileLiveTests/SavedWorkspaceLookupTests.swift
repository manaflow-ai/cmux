import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// Leo, 2026-11-24: "holy shit this is a huge problem in ios... wer need to chase all these
/// placeholders doen and prevent them". A chat opened on a workspace the live list does not hold
/// yet (past the first screen of cached rows, a cold open from a notification) resolves it from
/// the snapshot this phone saved, so it draws its kept turns instead of "Loading chat…".
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2))) struct SavedWorkspaceLookupTests {
    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"

    /// Two hundred saved rows on one Mac, oldest first: the head keeps the first screen's 40 and
    /// the 40 newest, so `w100` is only in the tail.
    func coordinator(store: AppStore) -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-saved-ws-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        let rows = (0 ..< 200).map { n in
            Workspace(id: "w\(n)", macID: "m1", title: "ws \(n)", directory: "~/p\(n)",
                      tabs: [WorkspaceTab(id: "s\(n)", kind: .agent, title: "Claude", harness: "claude")],
                      lastActivityAt: Date(timeIntervalSince1970: 1_000 + Double(n)))
        }
        snapshots.save(LiveSnapshot(
            teamID: "t1", teamName: "One", macs: [MacDevice(id: "m1", name: "Studio", isOnline: true)], linkedMacID: "m1",
            workspaces: ["m1": .init(workspaces: rows, savedAt: Date(timeIntervalSince1970: 5_000))]
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: MockDialer(fail: true),
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    @Test func aWorkspacePastTheFirstScreenResolvesFromTheSavedSnapshot() {
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = coordinator(store: store)
        defer { live.stop() }
        // The first screen's rows and the tail's both resolve, in this turn (no network, no wait).
        #expect(store.savedWorkspace("w0")?.tabs.first?.id == "s0")
        let tail = store.savedWorkspace("w100")
        #expect(tail?.macID == "m1")
        #expect(tail?.tabs.first?.id == "s100")
        #expect(store.savedWorkspace("never-saved") == nil, "never saved: nothing to draw from")
    }

    @Test func anotherSpaceOrSignOutResolvesNothing() {
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = coordinator(store: store)
        #expect(store.savedWorkspace("w0") != nil)
        store.activeTeamID = "t2"
        #expect(store.savedWorkspace("w0") == nil, "another space's saved rows never open")
        store.activeTeamID = "t1"
        live.stop()
        #expect(store.savedWorkspace("w0") == nil, "signed out: nothing saved resolves")
    }
}
#endif

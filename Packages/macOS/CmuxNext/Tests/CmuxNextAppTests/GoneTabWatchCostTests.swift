@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A tab-list change costs the gone-tab watch the tabs it tracks, not the session (CLAUDE.md "Go
/// past Chrome where cmux is scripted": a script that adds tabs, moves panes or makes columns in
/// 50 background workspaces must not make every watcher walk every tab of every workspace).
@MainActor struct GoneTabWatchCostTests {
    /// `count` workspaces of one pane with `tabs` tabs; workspace 0 gets one more tab with `grown`, and is closed
    /// with `closingFirst`.
    private static func session(_ count: Int, tabs: Int = 3, grown: Bool = false, closingFirst: Bool = false) -> DaemonTree {
        DaemonTree(workspaces: ((closingFirst ? 1 : 0)..<count).map { index in
            let base = UInt64(index * 100)
            let extra = grown && index == 0 ? 1 : 0
            let pane = PaneSnapshot(id: PaneID(rawValue: base + 1),
                                    tabs: (0..<(tabs + extra)).map { TabSnapshot(surface: SurfaceID(rawValue: base + 10 + UInt64($0)), title: "~") })
            let screen = ScreenSnapshot(id: ScreenID(rawValue: base + 2), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: base + 3), key: nil, name: "w\(index)", screens: [screen])
        })
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"gone-tab-cost-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }


    @Test(arguments: [50, 500])
    func aTabListChangeVisitsOnlyTheTrackedTabs(sessionSize: Int) async throws {
        let store = DaemonStore()
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.session(sessionSize))
        let tracked = try #require(store.tab(surface: SurfaceID(rawValue: 100 + 10)))
        let work = linklessMainWork()
        let watch = GoneTabWatch(mainWork: work)
        var released: [String] = []
        watch.track(tracked.id, in: store) { released.append($0) }
        let before = watch.tabsVisited

        // Another workspace gets a tab: the tab list changed, the tracked tab did not go (a posted background walk).
        store.apply(snapshot: Self.session(sessionSize, grown: true))
        _ = runMainLoop { work.postedCount(.background) == 0 }

        let visited = watch.tabsVisited - before
        #expect(visited <= 2, "one tab-list change visited \(visited) tabs in a \(sessionSize)-workspace session to watch one tab")
        #expect(released.isEmpty, "a tab the tree still lists was released")
    }

    /// The walk is one posted background task per burst, not one hop per change.
    @Test func aBurstOfTabListChangesIsOneWalkInOnePostedTask() throws {
        let store = DaemonStore()
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.session(10))
        let tracked = try #require(store.tab(surface: SurfaceID(rawValue: 10)))
        let work = linklessMainWork()
        let watch = GoneTabWatch(mainWork: work)
        watch.track(tracked.id, in: store) { _ in }
        let before = watch.tabsVisited
        for grown in [true, false, true] { store.apply(snapshot: Self.session(10, grown: grown)) }
        #expect(watch.tabsVisited == before, "a change walked in its own turn")
        #expect(work.postedCount(.background) == 1, "three changes, \(work.postedCount(.background)) posted walks")
        #expect(runMainLoop { work.postedCount(.background) == 0 }, "the posted walk never ran")
        #expect(watch.tabsVisited - before == 1, "three changes, \(watch.tabsVisited - before) visits of the one tracked tab")
    }

    /// A person's workspace close applies the watch in their input-response pass, which only
    /// posts the walk: no tab is visited and nothing is released before their commit; the background walk does it later.
    @Test func aPersonsWorkspaceCloseReleasesNothingInTheirInputResponsePass() throws {
        let rig = LinkedWork()
        let store = DaemonStore(causes: rig.work.causes)
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.session(10))
        let tracked = try #require(store.tab(surface: SurfaceID(rawValue: 10)))
        let watch = GoneTabWatch(mainWork: rig.work)
        var released: [String] = []
        watch.track(tracked.id, in: store) { released.append($0) }
        let loop = SweepCommitLoop()
        let pass = InputResponsePass(budget: rig.work.budget, runLoop: loop)
        pass.addSource(rig.work.causes)
        let before = watch.tabsVisited
        var atCommit: (released: [String], visited: Int)?
        loop.atCommit = { atCommit = (released, watch.tabsVisited - before) }

        // A key in the App's order: the dispatch begins, the person closes workspace 0, the input reports.
        rig.work.noteDiscreteDispatch(began: true)
        rig.work.causes.withCause(.person) { store.apply(snapshot: Self.session(10, closingFirst: true)) }
        rig.work.noteDiscreteInput(expectsFrame: true)
        rig.work.noteDiscreteDispatch(began: false)
        loop.turn()
        #expect(pass.stats.observations >= 1, "the person's tab-list change was not applied in their input-response pass")
        #expect(atCommit?.released == [], "a release ran before the person's commit")
        #expect(atCommit?.visited == 0, "the walk ran before the person's commit")

        for frame in 1...40 where released.isEmpty { rig.fire(frame) }
        #expect(released == [tracked.id], "the background walk did not release the closed workspace's tab")
    }

    /// The background walk yields to the person's pending input (a frame with input pending runs
    /// none of it), then runs once the input is handled.
    @Test func theWalkYieldsToThePersonsPendingInput() throws {
        let rig = LinkedWork()
        let store = DaemonStore(causes: rig.work.causes)
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.session(10))
        let tracked = try #require(store.tab(surface: SurfaceID(rawValue: 10)))
        let watch = GoneTabWatch(mainWork: rig.work)
        var released: [String] = []
        watch.track(tracked.id, in: store) { released.append($0) }
        let before = watch.tabsVisited

        // A script closes workspace 0 while the person has a key pending.
        store.apply(snapshot: Self.session(10, closingFirst: true))
        rig.keys.pending = true
        rig.fire(1)
        #expect(watch.tabsVisited == before, "the walk ran in a frame with the person's input pending")
        #expect(released.isEmpty, "a release ran in a frame with the person's input pending")

        rig.keys.pending = false
        for frame in 2...20 where released.isEmpty { rig.fire(frame) }
        #expect(released == [tracked.id], "the walk never ran after the input was handled")
    }
}

/// A scheduler on a fake link the test fires, whose budget reads the test's clock and pending-input flag; a keeper
/// client holds the link up, so posts wait for the frames the test fires.
@MainActor
private struct LinkedWork {
    let work: MainWorkScheduler
    let keys = WalkPendingKeys()
    private let clock = WalkBudgetClock()
    private let keeper: FrameClient

    init() {
        let clock = clock, keys = keys
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: keys, uptimeNanos: clock.read), clock: ManualClock()) { _ in WalkLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// One display frame, 17 ms after the last.
    func fire(_ frame: Int) {
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
    }
}

/// Whether a person's input waits (the test sets it).
@MainActor
private final class WalkPendingKeys: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class WalkBudgetClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [unowned self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class WalkLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

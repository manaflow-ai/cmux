@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// The app tells the local daemon which tabs it shows (`frontend.visibility.set`): one report a
/// frame for any number of flips, only when the set changed, each connection told afresh, nothing to a daemon
/// without `frontend-visibility-v1`, and `null` on the line for a clear.
@MainActor @Suite(.serialized) struct FrontendVisibilityReporterTests {
    /// What the fake daemon received; the reporter sends from its pump off main.
    @MainActor final class Received {
        var requests: [FrontendVisibilitySetRequest] = [] {
            didSet { resumeWaiter() }
        }
        var fails = false
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        /// Returns once `count` requests arrived, or when the test is cancelled (its time limit), so a missing
        /// request fails the test instead of hanging the suite.
        func reach(_ count: Int) async {
            guard requests.count < count else { return }
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = (count, $0) }
            } onCancel: {
                // The waiter is set on main before this hop runs: the body stores it in the job that suspends.
                Task { @MainActor in self.resumeWaiter(cancelled: true) }
            }
        }

        private func resumeWaiter(cancelled: Bool = false) {
            guard let waiter, cancelled || requests.count >= waiter.count else { return }
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    /// A store with three one-tab panes (surfaces 1, 2 and 3) on a daemon that serves `capabilities`.
    private static func store(capabilities: [String] = [DaemonCapability.frontendVisibility.rawValue]) -> DaemonStore {
        let store = DaemonStore()
        _ = store.apply(.connected(DaemonIdentity(capabilities: capabilities, generation: "boot"), generationChanged: true))
        load(store)
        return store
    }

    /// Applies the three-pane tree.
    private static func load(_ store: DaemonStore) {
        let panes = (1...3).map { id in
            PaneSnapshot(id: PaneID(rawValue: UInt64(id)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(id)), title: "~")])
        }
        let layout = panes.dropFirst().reduce(LayoutNode.leaf(panes[0].id)) { node, pane in
            .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: node, b: .leaf(pane.id))
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: panes)
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w",
                                                                         screens: [screen])]))
    }

    private static func work() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil }
    }

    /// The display frames, by hand: the reporter's frame work waits here until the test runs it.
    @MainActor final class Frames {
        private var pending: [@MainActor () -> Void] = []
        var count: Int { pending.count }

        func enqueue(_ work: @escaping @MainActor () -> Void) { pending.append(work) }

        /// Runs this frame's work; returns how much there was.
        @discardableResult func run() -> Int {
            let work = pending
            pending = []
            for item in work { item() }
            return work.count
        }
    }

    private static func reporter(_ store: DaemonStore, frames: Frames, daemon: Received) -> FrontendVisibilityReporter {
        FrontendVisibilityReporter(store: store, on: work(), frame: { frames.enqueue($0) }) { request in
            daemon.requests.append(request)
            return !daemon.fails
        }
    }

    /// The window and one tab node per surface, followed by `reporter`, all hidden. A tab holds its parent weakly:
    /// the caller keeps the window, or every tab is hidden for good.
    private static func nodes(_ store: DaemonStore, _ reporter: FrontendVisibilityReporter) throws
        -> (window: VisibilityNode, tabs: [VisibilityNode]) {
        let window = VisibilityNode(root: "window", own: .visible)
        let tabs = try (1...3).map { surface in
            let key = try #require(store.tab(surface: SurfaceID(rawValue: UInt64(surface)))).id
            let node = VisibilityNode("tab:\(key)", own: .hidden, parent: window)
            reporter.track(key, node: node)
            return node
        }
        return (window, tabs)
    }

    @Test(.timeLimit(.minutes(1))) func flipsInOneFrameSendOneSetAndOnlyWhenItChanged() async throws {
        let store = Self.store()
        let daemon = Received()
        let frames = Frames()
        let reporter = Self.reporter(store, frames: frames, daemon: daemon)
        let (window, tabs) = try Self.nodes(store, reporter)
        #expect(reporter.connection != nil)
        // The connection is told its first set: nothing shows yet.
        #expect(frames.run() == 1)
        await daemon.reach(1)
        #expect(daemon.requests == [FrontendVisibilitySetRequest(visible: [])])

        tabs[0].set(.visible)
        tabs[1].set(.visible)
        #expect(frames.count == 1, "one report for the frame, however many flips")
        frames.run()
        await daemon.reach(2)
        #expect(daemon.requests.last == FrontendVisibilitySetRequest(visible: [1, 2]))

        // A flip and its undo inside the frame send nothing.
        tabs[2].set(.visible)
        tabs[2].set(.hidden)
        #expect(frames.run() == 1)
        await drainMainTurns()
        #expect(daemon.requests.count == 2)

        // Hiding the window hides both tabs: one more set, empty, from one frame.
        window.set(.hidden)
        #expect(frames.run() == 1)
        await daemon.reach(3)
        #expect(daemon.requests.last == FrontendVisibilitySetRequest(visible: []))
        #expect(frames.run() == 0)
        withExtendedLifetime((reporter, window, tabs)) {}
    }

    @Test(.timeLimit(.minutes(1))) func everyConnectionIsToldAndAFailedSendIsResentOnTheNextChange() async throws {
        let store = Self.store()
        let daemon = Received()
        let frames = Frames()
        let reporter = Self.reporter(store, frames: frames, daemon: daemon)
        let (window, tabs) = try Self.nodes(store, reporter)
        tabs[0].set(.visible)
        frames.run()
        await daemon.reach(1)
        #expect(daemon.requests == [FrontendVisibilitySetRequest(visible: [1])])

        // The daemon restarts: nothing is sent while it is down, and its new connection is told the same set.
        store.apply(.disconnected(reason: "daemon exited"))
        await drainMainTurns()
        #expect(reporter.told == nil)
        frames.run()
        _ = store.apply(.connected(DaemonIdentity(capabilities: [DaemonCapability.frontendVisibility.rawValue], pid: 2,
                                                  generation: "restarted"), generationChanged: true))
        Self.load(store)  // the restarted daemon's tree
        await drainMainTurns()
        frames.run()
        await daemon.reach(2)
        #expect(daemon.requests.last == FrontendVisibilitySetRequest(visible: [1]))

        // A refused send leaves nothing told, so the next change sends the whole set again; it never retries alone.
        daemon.fails = true
        tabs[1].set(.visible)
        frames.run()
        await daemon.reach(3)
        await drainMainTurns()
        #expect(reporter.told == nil)
        #expect(frames.count == 0)
        daemon.fails = false
        tabs[2].set(.visible)
        frames.run()
        await daemon.reach(4)
        #expect(daemon.requests.last == FrontendVisibilitySetRequest(visible: [1, 2, 3]))
        withExtendedLifetime((reporter, window, tabs)) {}
    }

    @Test func aDaemonWithoutTheCapabilityIsNotTold() async throws {
        let store = Self.store(capabilities: [])
        let daemon = Received()
        let frames = Frames()
        let reporter = Self.reporter(store, frames: frames, daemon: daemon)
        let (window, tabs) = try Self.nodes(store, reporter)
        tabs[0].set(.visible)
        frames.run()
        await drainMainTurns()
        #expect(daemon.requests.isEmpty)
        withExtendedLifetime((reporter, window, tabs)) {}
    }

    @Test func onlyTheLocalDaemonReports() {
        let mainWork = Self.work()
        let cloud = DaemonService(machineID: "vm-visibility", mainWork: mainWork)
        cloud.reportFrontendVisibility(on: mainWork)
        #expect(cloud.frontendVisibility == nil)
        let local = DaemonService(mainWork: mainWork)
        local.reportFrontendVisibility(on: mainWork)
        #expect(local.frontendVisibility != nil)
    }

    @Test func theLineCarriesTheSetAndNullForAClear() throws {
        let set = try line(FrontendVisibilitySetRequest(visible: [3, 7]))
        #expect(set["cmd"] as? String == "frontend.visibility.set")
        #expect(set["visible"] as? [Int] == [3, 7])
        let clear = try line(FrontendVisibilitySetRequest(visible: nil))
        #expect(clear.keys.contains("visible"))
        #expect(clear["visible"] is NSNull)
        #expect(FrontendVisibilitySetRequest.requiredCapability == "frontend-visibility-v1")
    }

    private func line(_ request: FrontendVisibilitySetRequest) throws -> [String: Any] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

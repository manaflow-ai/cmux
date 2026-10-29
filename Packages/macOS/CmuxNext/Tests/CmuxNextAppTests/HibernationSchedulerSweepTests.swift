import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextApps
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The CmuxNextApp/{Hibernation,BrowserProfiles,Screenshots,Apps,Screens,LayoutTemplates} sweep
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, rule 9): one case per migrated owner class
/// on a rig whose frames the test fires. A service's follow is a classed task that runs with no window and no node, a
/// list read off main lands in one visible task, a hidden workspace's bar applies nothing until it shows, a person's
/// app command ends in userBlocking and a CLI's in automation, and the waits end on their condition or their deadline.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HibernationSchedulerSweepTests {
    // MARK: ServiceObservation (AgentPageHibernation.followTurns)

    @Test func aBurstOfTurnChangesReplansInOneBackgroundTask() {
        let rig = MainDeadlineRig()
        let hibernation = AgentPageHibernation(tabs: { nil }, deadlines: rig.deadlines)
        let turns = AgentTurnStateStore()
        hibernation.followTurns(turns)
        #expect(rig.deadlines.work.postedCount(.background) == 0, "the follow's first apply was posted, not run in its turn")

        turns.watching = true
        turns.watching = false
        #expect(rig.deadlines.work.postedCount(.background) == 1, "a burst of turn changes was not one background task")
        #expect(rig.deadlines.work.postedCount(.visible) == 0, "a program's turn change took a visible task")

        rig.frame()
        #expect(rig.deadlines.work.postedCount(.background) == 0, "the turn follow did not run in its frame")
    }

    // MARK: R-hop (LayoutTemplateLibrary's launch read)

    @Test func theLaunchReadListsTheTemplatesInOneVisibleTask() async throws {
        let rig = MainDeadlineRig()
        let repository = LayoutTemplateRepository(fileURL: nil)
        _ = try await repository.put(name: "Two up", blueprint: LayoutTemplateTests.blueprint)
        let library = LayoutTemplateLibrary(repository: repository, mainWork: rig.deadlines.work)

        let read = library.beginLoad()
        let end = ContinuousClock.now + .seconds(5)
        while rig.deadlines.work.postedCount(.visible) == 0, ContinuousClock.now < end { await Task.yield() }
        #expect(rig.deadlines.work.postedCount(.visible) == 1, "the read's list was not queued as one visible task")
        #expect(library.templates.isEmpty, "the list applied in the read's resume, before its task ran")

        rig.frame()
        await read.value
        #expect(library.templates.map(\.name) == ["Two up"])
        #expect(library.beginLoad() == read, "a second load read the file again")
    }

    // MARK: VisibleObservation, hidden (ScreenBarController)

    /// A hidden workspace's screen bar reads nothing while hidden: a new screen and a new strip height apply once,
    /// in its show turn, and the new height lays the bar's container out again (the relayout WorkspaceContentView
    /// had its own observation for). Shown, a new height lays it out again on a frame.
    @Test func aHiddenWorkspacesScreenBarAppliesNothingUntilItShowsThenOnce() async throws {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        let store = services.daemon.store
        store.connectionState = .connected(try Self.identity())
        store.apply(snapshot: Self.tree(screens: 1))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        // The controller holds its window state unowned: the test keeps it alive, as its window does.
        let state = WindowState(record: record)
        let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        let node = VisibilityNode(root: "test.workspace", own: .hidden)
        let bar = ScreenBarController(content: content, node: node)
        let seen = SweepSeen()
        bar.onVisibilityChange = { seen.barShown.append($0) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.addSubview(bar.view)
        defer {
            DesignSettings.shared.setOverride(.tabStripHeight, nil)
            bar.teardown()
            content.teardown()
            withExtendedLifetime((services, state)) {}
        }
        #expect(bar.model.tabs.count == 1)

        store.apply(snapshot: Self.tree(screens: 2))
        Self.changeStripHeight()
        container.needsLayout = false
        Self.spin(frames: 5, rig: rig)
        #expect(seen.barShown.isEmpty, "a hidden workspace's bar applied a change nobody sees")
        #expect(bar.model.tabs.count == 1, "a hidden workspace's bar read its screens")
        #expect(!container.needsLayout, "a hidden workspace's bar laid its container out")

        node.set(.visible)
        #expect(seen.barShown == [true], "the show did not apply the bar's final state once")
        #expect(bar.model.tabs.count == 2)
        #expect(container.needsLayout, "a strip height changed while hidden did not lay the container out on show")

        container.needsLayout = false
        Self.changeStripHeight()
        Self.spin(until: { container.needsLayout }, rig: rig)
        #expect(container.needsLayout, "a new strip height did not lay the shown bar's container out again")
        #expect(seen.barShown == [true], "a strip height change re-told the bar's visibility")
    }

    // MARK: Person and automation (AppCommandPalette.run)

    /// The rest of a person's palette command is one userBlocking task; a CLI's is automation.
    @Test func anAppCommandsResultRunsInItsCallersClass() {
        #expect(Self.appCommandResultClass(.user) == .userBlocking, "a person's app command did not end in userBlocking")
        #expect(Self.appCommandResultClass(.cli) == .automation, "a CLI's app command did not end in automation")
    }

    // MARK: ObservedCondition, automation (AgentBrowserProfile.ensure)

    @Test func theAgentProfileWaitEndsWhenTheRecordIsReported() async throws {
        let rig = MainDeadlineRig(), flag = SweepFlag()
        let wait = Task { try await AgentBrowserProfile.reported(within: .seconds(5), on: rig.deadlines.work, deadlines: rig.deadlines) { flag.isOn } }
        while !rig.hasArmedWake { await Task.yield() }
        flag.isOn = true
        Self.spin(until: { !rig.hasArmedWake }, rig: rig)
        try await wait.value
        #expect(!rig.hasArmedWake, "the reported record left the wait's deadline armed")
        #expect(rig.elapsed < 5, "the wait ran to its deadline")
    }

    @Test func theAgentProfileWaitThrowsNotReportedAtItsDeadline() async {
        let rig = MainDeadlineRig(), flag = SweepFlag()
        let wait = Task { try await AgentBrowserProfile.reported(within: .seconds(5), on: rig.deadlines.work, deadlines: rig.deadlines) { flag.isOn } }
        while !rig.hasArmedWake { await Task.yield() }
        rig.fireAndRun()
        await #expect(throws: AgentBrowserProfile.NotReported.self) { try await wait.value }
        #expect(rig.elapsed >= 5, "the wait ended \(rig.elapsed) s in, before its 5 s deadline")
    }

    // MARK: R-wait (BrowserHibernation.timeLoad)

    /// An engine page's wake is timed by its keyed phase wait: loaded_ms once its load finishes.
    @Test func anEnginePagesWakeRecordsItsLoadWhenItFinishes() async throws {
        let (rig, services, hibernation) = Self.hibernation()
        let tab = MockBrowserEngine(completesNavigationsImmediately: false).makeMockTab(BrowserTabConfiguration(initialURL: nil))
        _ = services.cache.install(tab, for: "woken")
        let id = tab.makeNavigationID()
        tab.simulate(.started(id, url: URL(string: "https://example.com")))
        Self.startWake("woken", engine: .webkit, on: hibernation)

        hibernation.timeLoad("woken", page: tab)
        await tab.pageWaiters.untilPending(1)
        #expect(hibernation.wakeLog.records.last?.loadedMs == nil, "a page still loading recorded its load")
        tab.simulate(.finished(id))
        Self.spin(until: { hibernation.wakeLog.records.last?.loadedMs != nil }, rig: rig)
        #expect(hibernation.wakeLog.records.last?.loadedMs != nil, "the engine page's load end was not recorded")
        withExtendedLifetime((services, hibernation)) {}
    }

    /// A woken page with no keyed waits (a streamed or a cmux page) that is still loading at its mount keeps its
    /// wake open: loaded_ms once its phase finishes, read by an observed condition.
    @Test func aWokenPageWithNoKeyedWaitsRecordsItsLoadWhenItFinishes() async throws {
        let (rig, services, hibernation) = Self.hibernation()
        let page = PhaseOnlyTab()
        page.state.phase = .committed
        _ = services.cache.install(page, for: "streamed")
        Self.startWake("streamed", engine: .webkit, on: hibernation)

        hibernation.timeLoad("streamed", page: page)
        Self.spin(frames: 5, rig: rig)
        #expect(hibernation.wakeLog.records.last?.loadedMs == nil, "a page still loading recorded its load")
        page.state.phase = .finished
        Self.spin(until: { hibernation.wakeLog.records.last?.loadedMs != nil }, rig: rig)
        #expect(hibernation.wakeLog.records.last?.loadedMs != nil, "the load end of a page with no keyed waits was not recorded")
        withExtendedLifetime((services, hibernation)) {}
    }

    // MARK: Helpers

    private static func hibernation() -> (MainDeadlineRig, AppServices, BrowserHibernation) {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let services = AppServices(environment: AppEnvironment.current([:]), mainWork: rig.deadlines.work)
        return (rig, services, BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: rig.deadlines))
    }

    /// A wake of `key` started and its page mounted, as `restore` and `finishRestore` record them.
    private static func startWake(_ key: String, engine: BrowserEngineKind, on hibernation: BrowserHibernation) {
        hibernation.wakeLog.start(key, engine: engine, snapshot: false)
        hibernation.wakeLog.mounted(key, visible: true)
    }

    /// The class the result of an app command from `origin` ran in, from the scheduler's owner ledger.
    private static func appCommandResultClass(_ origin: ActionOrigin) -> MainWorkClass? {
        let rig = MainDeadlineRig(), seen = SweepSeen()
        let run = AppCommandPalette.run(origin: origin, on: rig.deadlines.work) { () async throws(AppsClientError) in }
        // task-owner: the test's one read of the run's result
        Task { _ = await run.value; seen.finished = true }
        spin(until: { seen.finished }, rig: nil)
        return rig.deadlines.work.budget.board.ownerSnapshot().owners.first { $0.owner == "app.command.run" }?.workClass
    }

    /// Overrides the design's strip height with a value that differs from the one in effect (the reset is the caller's).
    private static func changeStripHeight() {
        let old = Metrics.tabStripHeight
        for raw: CGFloat in [26, 38, 30] {
            DesignSettings.shared.setOverride(.tabStripHeight, raw)
            if Metrics.tabStripHeight != old { return }
        }
    }

    private static func identity() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"hibernation-sweep-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// One workspace with `screens` screens of one pane each.
    private static func tree(screens: Int) -> DaemonTree {
        let shots = (1...screens).map { id -> ScreenSnapshot in
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(id)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(id)), title: "~")])
            return ScreenSnapshot(id: ScreenID(rawValue: UInt64(id)), layout: .leaf(pane.id), panes: [pane])
        }
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: shots)])
    }

    /// `frames` main run loop passes, each with a frame.
    private static func spin(frames: Int, rig: MainDeadlineRig) {
        for _ in 0..<frames {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            rig.frame()
        }
    }

    /// Main run loop passes (where off-main posts and main-actor resumes arrive) and, with a rig, frames, until
    /// `done` or 5 s.
    private static func spin(until done: () -> Bool, rig: MainDeadlineRig?) {
        let end = Date(timeIntervalSinceNow: 5)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            rig?.frame()
        }
    }
}

@MainActor @Observable
private final class SweepFlag {
    var isOn = false
}

@MainActor
private final class SweepSeen {
    var barShown: [Bool] = []
    var finished = false
}

/// A page with no keyed waits (as a streamed page or a cmux page): its phase is plain observable state.
@MainActor @Observable
private final class PhaseOnlyTab: BrowserTab {
    let id = BrowserTabID.random()
    let engineKind: BrowserEngineKind = .webkit
    let profileID: BrowserProfileID = .default
    let presentation: BrowserPresentation = .inView
    @ObservationIgnored let contentView = NSView()
    var state = BrowserTabState()
    let favicon: NSImage? = nil
    let pendingPrompts: [BrowserPrompt] = []
    @ObservationIgnored weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored weak var keyRouter: (any BrowserKeyRouting)?

    func load(_ url: URL) {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stop() {}
    func setFocused(_ focused: Bool) {}
    func setContentVisible(_ visible: Bool) {}
    func snapshot() async throws -> CGImage { throw BrowserTabError.snapshotUnavailable }
    func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
        throw BrowserTabError.unsupported("evaluate")
    }
    func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult { .none }
    func clearFind() {}
    func setZoom(_ zoom: Double) {}
    func exitContentFullscreen() {}
    func showDevTools() {}
    func close() {}
}

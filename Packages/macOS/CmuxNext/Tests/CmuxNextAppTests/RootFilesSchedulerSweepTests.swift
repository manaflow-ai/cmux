import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSidebar
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Observation
import Testing

/// The CmuxNextApp root files T* to W* sweep (plans/cmux-next/chrome-parity/p06-scheduler.md),
/// one harness case per migrated owner class (rule 9):
/// - a wait for a tab ends on the change that brings it, through one keyed waiter and one posted task, never a poll
///   or a Task per change;
/// - hidden content (a parked workspace) reads and applies nothing for its views, and applies once when it shows;
/// - a person's tree change lays out in their input-response pass, before the commit;
/// - a service's side effects (a hidden terminal's stall and exit) still happen while nothing shows.
/// The background class (the gone-tab walk) is in `GoneTabWatchCostTests`, the window root in
/// `MainPaneGutterSuites.WindowRootHiddenTests`.
@MainActor @Suite(.timeLimit(.minutes(1))) struct RootFilesSchedulerSweepTests {
    @Test func aTabAlreadyInTheTreeEndsTheWaitWithNoObservation() async {
        let lookup = TabLookup(), work = linklessMainWork()
        lookup.found = true
        #expect(await TabMirror.reaches("t1", in: { lookup.locate($0) }, on: work))
        #expect(lookup.reads == 1, "a satisfied wait read the tree \(lookup.reads) times")
    }

    @Test func aTabMirrorWaitEndsInThePostedTaskAfterTheTreeHasTheTab() async {
        let lookup = TabLookup(), work = linklessMainWork()
        let waiter = Task { await TabMirror.reaches("t1", in: { lookup.locate($0) }, on: work) }
        // Filed: the first check, the observation's first read and the waiter's own first read.
        while lookup.reads < 3 { await Task.yield() }
        let filed = lookup.reads
        for _ in 0..<5 { lookup.unrelated += 1 }
        #expect(lookup.reads == filed, "a change the lookup does not read made it read again")

        lookup.found = true
        #expect(work.postedCount(.visible) == 1, "the change posted no flush")
        #expect(runMainLoop { work.postedCount(.visible) == 0 }, "the posted flush never ran")
        #expect(await waiter.value, "the wait did not end when the tree got the tab")
        // The re-armed tracking, the flush and the waiter's settle.
        #expect(lookup.reads - filed <= 3, "one change, \(lookup.reads - filed) reads")
    }

    /// Hidden -> 0 view reads and applies, 1 apply on show: a parked workspace's attention rings follow its node.
    @Test func aParkedWorkspaceReadsNoAttentionUntilItShowsThenAppliesOnce() throws {
        let rig = try ContentRig()
        defer { rig.close() }
        let ledger = rig.services.mainWork.observations
        let counts = { ledger.snapshot(matching: "WorkspaceContent.attention").first }
        rig.content.contentView.isHidden = true
        rig.content.park(serial: 1)
        let before = counts()

        // A notification makes the parked workspace's only tab unread.
        rig.store.apply(snapshot: ContentRig.tree(panes: 1, unread: true))
        spinMainLoop()
        #expect(counts()?.evaluations == before?.evaluations, "a parked workspace read its attention marks")
        #expect(counts()?.applies == before?.applies, "a parked workspace applied its attention marks")
        #expect(rig.content.layoutModel.attention.isEmpty, "a parked workspace drew a ring nobody sees")

        rig.content.unpark()
        rig.content.contentView.isHidden = false
        #expect(runMainLoop { rig.content.layoutModel.attention.count == 1 }, "showing it drew no ring for its unread tab")
        #expect(counts()?.applies == (before?.applies ?? 0) + 1, "showing it applied its marks \(counts()?.applies ?? 0) times")
    }

    /// Person -> applied before the commit: a person's tree change lays out in their input-response pass.
    @Test func aPersonsTreeChangeLaysOutInTheirTurnBeforeTheCommit() throws {
        let rig = try ContentRig()
        defer { rig.close() }
        let work = rig.services.mainWork
        let loop = SweepCommitLoop()
        let pass = InputResponsePass(budget: work.budget, runLoop: loop)
        pass.addSource(work.causes)
        var panesAtCommit: Int?
        loop.atCommit = { panesAtCommit = rig.content.layoutModel.screens.first?.layout.panes.count }

        // A key in the App's order: the dispatch begins, the person's split changes the tree, the input reports.
        work.noteDiscreteDispatch(began: true)
        work.causes.withCause(.person) { rig.store.apply(snapshot: ContentRig.tree(panes: 2)) }
        work.noteDiscreteInput(expectsFrame: true)
        work.noteDiscreteDispatch(began: false)
        loop.turn()
        #expect(panesAtCommit == 2, "the person's split was not laid out before their commit (\(panesAtCommit ?? 0) panes)")
        #expect(pass.stats.observations >= 1, "the input-response pass applied no observation")
    }

    /// Side effects still sent while hidden: a terminal in no window takes its shell's stall and its exit.
    @Test func aHiddenTerminalStillTakesItsStallAndExitFromTheDaemon() throws {
        _ = NSApplication.shared
        let work = linklessMainWork()
        let store = DaemonStore(causes: work.causes)
        store.apply(snapshot: ContentRig.tree(panes: 1))
        let scripted = ScriptedTerminalIO()
        defer { scripted.finish() }
        let session = TerminalSession(io: scripted, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let surface = SurfaceID(rawValue: 1)
        let attachment = TerminalAttachment.Target(surface: surface, terminalResourceID: nil, generation: nil)
        let io = DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: ResizeCoordinator(),
                                  visible: false, connection: { throw CancellationError() })
        // The session's view is in no window: nothing shows this terminal.
        let watch = TerminalLinkWatch(store: store, surface: surface, io: io, session: session, mainWork: work)
        defer { watch.stop() }

        Self.push(store, state: "failed")
        #expect(runMainLoop { session.shellStall != nil }, "a hidden terminal did not take its shell's stall")
        Self.push(store, state: "exited", dead: true)
        #expect(runMainLoop { if case .exited = io.attachPhase { true } else { false } }, "a hidden terminal was not told its process exited")
    }

    /// The daemon's `tab-changed` push for surface 1, as the subscribe stream sends it.
    private static func push(_ store: DaemonStore, state: String, dead: Bool = false) {
        let line = """
        {"event":"tab-changed","workspace":1,"screen":1,"pane":1,"surface":1,"index":0,\
        "entity":{"surface":1,"kind":"pty","title":"~","dead":\(dead),"terminal_state":"\(state)"}}
        """
        _ = store.apply(DaemonEvent.decode(name: "tab-changed", line: Data(line.utf8)))
    }
}

extension MainPaneGutterSuites {
    /// Hidden -> 0 view reads and applies, 1 apply on show, for the window root: its main pane follows the
    /// tunables only while its window's node shows. Under the gutter suites, as it sets the gutter.
    @MainActor @Suite struct WindowRootHiddenTests {
        @Test func aHiddenWindowReadsNoMainPaneTunablesAndAppliesThemOnceWhenShown() {
            _ = NSApplication.shared
            let store = TunableStore.shared
            let curved = ChromeTunables.mainPaneCurved
            store.register([curved.descriptor])
            if !store.isActive { store.activate(file: nil) }
            store.set(curved.key, .bool(true)) // the gutter applies only to a curved main pane
            defer { store.set(curved.key, nil) }
            let work = linklessMainWork()
            let node = VisibilityNode(root: "test.window", own: .visible)
            let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel(), mainWork: work), revealDeadlines: .testing())
            root.follow(on: node, work: work)
            let counts = { work.observations.snapshot(matching: "WindowRootView.mainPane").first }
            let before = counts()

            node.set(.hidden)
            MainPaneGutterSuites.withGutter(0) {
                spinMainLoop()
                #expect(counts()?.evaluations == before?.evaluations, "a hidden window read the main pane tunables")
                #expect(counts()?.applies == before?.applies, "a hidden window applied the main pane tunables")

                node.set(.visible)
                #expect(runMainLoop { counts()?.applies == (before?.applies ?? 0) + 1 },
                        "showing the window applied the gutter change \(counts()?.applies ?? 0) times")
            }
            withExtendedLifetime(root) {}
        }
    }
}

/// A workspace's content in a borderless window, on the app's services, as ParkedWorkspaceApplyTests builds it.
@MainActor
private struct ContentRig {
    let services: AppServices
    let store: DaemonStore
    let content: WorkspaceContentController
    let window: NSWindow
    /// The controller holds its window state unowned: the rig keeps it alive, as its window does.
    let state: WindowState

    init() throws {
        _ = NSApplication.shared
        services = AppServices(environment: AppEnvironment.current([:]))
        store = services.daemon.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"root-files-sweep-test","generation":"g1"}"#
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        store.apply(snapshot: Self.tree(panes: 1))
        let workspace = try #require(store.workspaces.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        state = WindowState(record: record)
        content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        content.contentView.layoutSubtreeIfNeeded()
    }

    func close() {
        withExtendedLifetime((services, state)) {
            content.teardown()
            window.close()
        }
    }

    /// One workspace (handle 1, screen 1) of `panes` side by side, pane and surface ids from 1; with `unread`,
    /// the first tab holds an unread notification.
    static func tree(panes: Int, unread: Bool = false) -> DaemonTree {
        let note = unread ? TabNotification(notification: NotificationID(rawValue: 7), unread: true, level: .info, source: "agent") : nil
        let snapshots = (1...panes).map { id in
            PaneSnapshot(id: PaneID(rawValue: UInt64(id)),
                         tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(id)), title: "~", notification: id == 1 ? note : nil)])
        }
        let layout = snapshots.dropFirst().reduce(LayoutNode.leaf(snapshots[0].id)) { node, pane in
            .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: node, b: .leaf(pane.id))
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: snapshots)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }
}

/// Runs the main run loop for about 100 ms: long enough for every posted task and hop a change makes.
@MainActor private func spinMainLoop() {
    for _ in 0..<10 { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
}

/// A run loop whose turn runs its queued blocks, then the commit stage's observers in order, and calls
/// `atCommit` where Core Animation's observer (order 2,000,000) runs.
@MainActor
final class SweepCommitLoop: InputResponseRunLoop {
    var atCommit: @MainActor () -> Void = {}
    private var observers: [SweepCommitObserver] = []
    private var blocks: [@MainActor () -> Void] = []

    func observeBeforeCommit(order: CFIndex, _ handler: @escaping @MainActor () -> Void) -> any InputResponseObservation {
        let observer = SweepCommitObserver(order: order, handler: handler)
        observers.append(observer)
        return observer
    }

    func perform(_ work: @escaping @MainActor () -> Void) {
        blocks.append(work)
    }

    func turn() {
        let queued = blocks
        blocks.removeAll()
        for block in queued { block() }
        var committed = false
        for observer in observers.filter(\.isValid).sorted(by: { $0.order < $1.order }) {
            if !committed, observer.order >= 2_000_000 {
                atCommit()
                committed = true
            }
            if observer.isValid { observer.handler() }
        }
        if !committed { atCommit() }
        observers.removeAll { !$0.isValid }
    }
}

private final class SweepCommitObserver: InputResponseObservation {
    let order: CFIndex
    let handler: @MainActor () -> Void
    private(set) var isValid = true

    init(order: CFIndex, handler: @escaping @MainActor () -> Void) {
        self.order = order
        self.handler = handler
    }

    func invalidate() { isValid = false }
}

/// A tree lookup whose answer the test flips; it counts its reads.
@MainActor @Observable
private final class TabLookup {
    var found = false
    var unrelated = 0
    @ObservationIgnored private(set) var reads = 0
    @ObservationIgnored private let daemon = DaemonService()

    func locate(_ key: String) -> (pane: PaneID, daemon: DaemonService)? {
        reads += 1
        return found ? (PaneID(rawValue: 1), daemon) : nil
    }
}

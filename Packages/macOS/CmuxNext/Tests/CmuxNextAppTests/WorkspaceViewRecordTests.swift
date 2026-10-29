import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextTabs
import Foundation
import Testing

/// A workspace its window unmounts (`WindowController.releaseParked`) comes back as it was:
/// its `WorkspaceViewRecord` keeps the strip, row, tab strip and screen bar
/// scrolls, and the next mount applies them before its first frame commits; the selected tabs stay
/// in the window's memory. The record holds at most 2 KB for 12 panes.
@MainActor struct WorkspaceViewRecordTests {
    // MARK: The camera restore (ColumnScrollState.pendingRestore)

    /// Six 600 pt columns, 10 pt apart.
    private static func strip(viewport: CGFloat) -> ColumnStrip {
        let columns = (0..<6).map { index in
            let frame = CGRect(x: CGFloat(index) * 610, y: 0, width: 600, height: 700)
            return ColumnStrip.Column(id: LayoutColumnID("c\(index)"), frame: frame, panes: [LayoutPaneID("p\(index)")],
                                      paneFrames: [LayoutPaneID("p\(index)"): frame])
        }
        return ColumnStrip(columns: columns, viewportWidth: viewport, contentWidth: 6 * 610 - 10, gap: 10)
    }

    @Test func aSavedCameraWaitsForARealViewportThenRestsThereWithNoFrames() {
        var state = ColumnScrollState()
        state.pendingRestore = 1210
        // Mounted out of its window: no viewport yet, so the saved offset waits.
        _ = state.reduce(.sync(Self.strip(viewport: 0), focused: LayoutPaneID("p2"), source: .programmatic, animated: false))
        #expect(state.pendingRestore == 1210)

        let effects = state.reduce(.sync(Self.strip(viewport: 1210), focused: LayoutPaneID("p2"), source: .programmatic, animated: true))
        #expect(state.pendingRestore == nil)
        #expect(state.spring.value == 1210 && state.spring.target == 1210, "the remount did not rest where the workspace was scrolled")
        #expect(!effects.needsFrames && !effects.snapped, "the restore animated instead of showing in the first frame")
        #expect(state.focusedPane == LayoutPaneID("p2"))
    }

    @Test func aSavedCameraStillRevealsTheFocusedPane() {
        var state = ColumnScrollState()
        state.pendingRestore = 2440
        // The focus moved to the first column while the workspace was unmounted: it shows.
        _ = state.reduce(.sync(Self.strip(viewport: 1210), focused: LayoutPaneID("p0"), source: .programmatic, animated: false))
        #expect(state.spring.target == 0)
    }

    @Test func aSavedCameraPastTheStripIsClamped() {
        var state = ColumnScrollState()
        state.pendingRestore = 9000
        _ = state.reduce(.sync(Self.strip(viewport: 1210), focused: LayoutPaneID("p5"), source: .programmatic, animated: false))
        #expect(state.spring.target == Self.strip(viewport: 1210).maxOffset)
    }

    // MARK: The record's budget

    /// What `record` holds on the heap, an upper bound: each dictionary's one allocation (its
    /// header, occupancy bitmap, and keys and values at its full bucket count) and each identifier's
    /// string storage when it is too long to be inline, counted as the record's own (the store's
    /// models share it while their panes live).
    private static func heldBytes(_ record: WorkspaceViewRecord) -> Int {
        func quanta(_ bytes: Int) -> Int { (bytes + 15) / 16 * 16 }
        // A native string: its 32-byte header, the UTF-8 bytes and a terminator; 15 bytes or fewer live inline.
        func string(_ value: String) -> Int { value.utf8.count <= 15 ? 0 : quanta(32 + value.utf8.count + 1) }
        func table<Key, Value>(_ table: [Key: Value], name: (Key) -> String) -> Int {
            guard !table.isEmpty else { return 0 }
            var buckets = 1
            while buckets * 3 / 4 < table.capacity { buckets *= 2 }
            let storage = 64 + (buckets + 63) / 64 * 8 + buckets * (MemoryLayout<Key>.stride + MemoryLayout<Value>.stride)
            return quanta(storage) + table.keys.reduce(0) { $0 + string(name($1)) }
        }
        var bytes = MemoryLayout<WorkspaceViewRecord>.stride
        bytes += table(record.screens) { $0.rawValue }
        for scroll in record.screens.values {
            bytes += table(scroll.rows) { $0.rawValue } + table(scroll.areas) { $0.rawValue }
        }
        bytes += table(record.tabStrips) { $0.rawValue }
        return bytes
    }

    /// A daemon resource id: `kind_` and 32 hex digits.
    private static func resourceID(_ kind: String, _ index: Int) -> String {
        let suffix = String(index, radix: 16)
        return kind + "_" + String(repeating: "0", count: 32 - suffix.count) + suffix
    }

    @Test func aTwelvePaneRecordHoldsAtMostTwoKilobytes() {
        // Every offset a 12-pane workspace can have on one screen: its strip, an overflowing row
        // column, each pane's tab strip and the screen bar.
        var record = WorkspaceViewRecord(screenBar: 212.5)
        record.screens[LayoutScreenID(Self.resourceID("screen", 1))] = LayoutScreenScroll(strip: 3660, rows: [LayoutColumnID(Self.resourceID("column", 1)): 480])
        for index in 1...12 { record.tabStrips[LayoutPaneID(Self.resourceID("pane", index))] = 96.5 }
        #expect(record.entryCount == 15)
        let bytes = Self.heldBytes(record)
        #expect(bytes <= 2048, "a 12-pane record holds \(bytes) bytes")
    }

    @Test func anUnscrolledStripRecordsNothing() {
        #expect(WorkspaceViewRecord.stripOffset(0) == nil)
        #expect(WorkspaceViewRecord.stripOffset(120) == 120)
        #expect(WorkspaceViewRecord().entryCount == 0)
    }

    // MARK: Unmount and remount

    /// Twelve half-width columns, one pane each, two tabs per pane.
    private static func tree() -> DaemonTree {
        let panes: [PaneSnapshot] = (1...12).map { (index: Int) -> PaneSnapshot in
            let raw = UInt64(index)
            let tabs: [TabSnapshot] = [TabSnapshot(surface: SurfaceID(rawValue: 2 * raw), title: "~"),
                                       TabSnapshot(surface: SurfaceID(rawValue: 2 * raw + 1), title: "~")]
            return PaneSnapshot(id: DaemonPaneID(rawValue: raw), tabs: tabs)
        }
        let columns: [ColumnSnapshot] = (1...12).map { (index: Int) -> ColumnSnapshot in
            let raw = UInt64(index)
            return ColumnSnapshot(id: DaemonColumnID(rawValue: 100 + raw), width: 0.5, layout: .leaf(DaemonPaneID(rawValue: raw)))
        }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    /// The shown screen: four half-width columns, one pane each with `tabs` tabs (the strips overflow),
    /// without the panes in `without`. Then `screens - 1` more screens of one single-tab pane each,
    /// so the screen bar shows and overflows a 600 pt window.
    private static func crowdedTree(tabs: Int = 40, screens: Int = 24, without: Set<Int> = []) -> DaemonTree {
        let kept = (1...4).filter { !without.contains($0) }
        let panes: [PaneSnapshot] = kept.map { (index: Int) -> PaneSnapshot in
            let strip: [TabSnapshot] = (0..<tabs).map { (tab: Int) -> TabSnapshot in
                TabSnapshot(surface: SurfaceID(rawValue: UInt64(1000 * index + tab)), title: "~")
            }
            return PaneSnapshot(id: DaemonPaneID(rawValue: UInt64(index)), tabs: strip)
        }
        let columns: [ColumnSnapshot] = kept.map { (index: Int) -> ColumnSnapshot in
            ColumnSnapshot(id: DaemonColumnID(rawValue: UInt64(100 + index)), width: 0.5, layout: .leaf(DaemonPaneID(rawValue: UInt64(index))))
        }
        let shown = ScreenSnapshot(id: 1, active: true, layout: .leaf(DaemonPaneID(rawValue: UInt64(kept[0]))), columns: columns, panes: panes)
        let others: [ScreenSnapshot] = (2...screens).map { (index: Int) -> ScreenSnapshot in
            let pane = PaneSnapshot(id: DaemonPaneID(rawValue: UInt64(10_000 + index)),
                                    tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(900_000 + index)), title: "~")])
            return ScreenSnapshot(id: DaemonScreenID(rawValue: UInt64(index)), layout: .leaf(pane.id), panes: [pane])
        }
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [shown] + others)])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"view-record-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func windowState() throws -> WindowState {
        WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8)))
    }

    private static func window(width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: width, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Installs `content` in `window` and lays it out: the layout pass before the first frame.
    private static func mount(_ content: WorkspaceContentController, in window: NSWindow, width: CGFloat = 1200) {
        content.contentView.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        window.contentView = content.contentView
        content.contentView.layoutSubtreeIfNeeded()
    }

    /// Scrolls a laid-out strip to the middle of its range, as a person's wheel would leave it, and
    /// returns where it rests.
    private static func scrollHalfway(_ strip: TabStripView) throws -> CGFloat {
        strip.restoreScrollOffset(.greatestFiniteMagnitude)
        let end = strip.restorableScrollOffset
        try #require(end > 100, "the strip does not overflow (\(end) pt of scroll)")
        strip.restoreScrollOffset((end / 2).rounded())
        return strip.restorableScrollOffset
    }

    @Test(.timeLimit(.minutes(1)))
    func aRemountedWorkspaceShowsTheStripScrollAndTheSelectionsItWasUnmountedWith() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let window = Self.window(width: 1200)
        // The controllers hold the window state unowned: the test keeps it alive, as a window does.
        let state = try Self.windowState()
        let mounted = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        mounted.layoutModel.centerFocusedColumnOverride = .never // a focus change scrolls the least that shows its column
        Self.mount(mounted, in: window)
        let order = try #require(mounted.layoutModel.screens.first?.layout.panes)
        #expect(order.count == 12)
        let far = order[6]
        // The person scrolled to the seventh column and focused it (the window's focus applier mirrors it).
        mounted.layoutModel.focus(far, notify: false)
        mounted.layoutView.syncWithModel()
        mounted.contentView.layoutSubtreeIfNeeded()
        // ...and picked each mounted pane's second tab.
        for controller in mounted.panes.values {
            controller.applySelection(StripTabID(try #require(controller.pane.tabs.last).id))
        }
        let selected = mounted.panes.mapValues { $0.stripModel.selectedID }
        var saved = mounted.viewRecord()
        let (screen, scroll) = try #require(saved.screens.first)
        let strip = try #require(scroll.strip)
        // Revealing the seventh column put its right edge at the viewport's. The person then scrolled
        // 400 pt further (it still shows): a mount that dropped the record would reveal it at the edge again.
        #expect(strip > 0, "the strip did not scroll to the seventh column")
        saved.screens[screen]?.strip = strip + 400
        mounted.teardown()

        // The same window mounts it again: its selection memory and focus machine kept what they had.
        let remounted = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state,
                                                   restoring: saved)
        defer { withExtendedLifetime((services, state)) { remounted.teardown(); window.close() } }
        remounted.layoutModel.centerFocusedColumnOverride = .never
        remounted.layoutModel.focus(far, notify: false)
        remounted.layoutView.syncWithModel()
        Self.mount(remounted, in: window)

        // The first layout pass (before the first frame) already shows the saved camera.
        let shown = try #require(remounted.layoutView.frame(of: far))
        #expect(shown.maxX < 1000, "the seventh column shows at \(shown), not 400 pt left of the viewport's edge")
        let restored = try #require(remounted.viewRecord().screens[screen]?.strip)
        #expect(abs(restored - (strip + 400)) < 0.5, "the remount's strip rests at \(restored), not \(strip + 400)")
        for (pane, tab) in selected {
            let controller = try #require(remounted.panes[pane], "pane \(pane) did not mount again")
            #expect(controller.stripModel.selectedID == tab, "pane \(pane) shows another tab")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aRemountShowsEveryTabStripAndTheScreenBarWhereTheyWereScrolled() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.crowdedTree())
        let workspace = try #require(store.workspaces.first)
        let window = Self.window(width: 600)
        let state = try Self.windowState()
        let mounted = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        Self.mount(mounted, in: window, width: 600)
        let active = try #require(mounted.layoutModel.activeScreenID)
        let order = try #require(mounted.layoutModel.screens.first { $0.id == active }?.layout.panes)
        #expect(order.count == 4)
        #expect(mounted.screenBar.isVisible, "24 screens and no screen bar")
        var strips: [LayoutPaneID: CGFloat] = [:]
        for pane in order {
            strips[pane] = try Self.scrollHalfway(try #require(mounted.panes[pane], "pane \(pane) did not mount").view.stripView)
        }
        let bar = try Self.scrollHalfway(mounted.screenBar.view)
        let saved = mounted.viewRecord()
        #expect(saved.tabStrips == strips, "the record's tab strips \(saved.tabStrips) are not the scrolled ones \(strips)")
        #expect(saved.screenBar == bar)
        mounted.teardown()

        // Meanwhile the last column's pane left the tree (a reconnect that lists it later): the
        // remount mounts the other three and keeps its offset until it mounts.
        let late = order[3]
        store.apply(snapshot: Self.crowdedTree(without: [4]))
        let remounted = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state,
                                                   restoring: saved)
        defer { withExtendedLifetime((services, state)) { remounted.teardown(); window.close() } }
        Self.mount(remounted, in: window, width: 600)
        #expect(remounted.panes[late] == nil)
        // The first layout pass already shows each strip and the bar where they were.
        for pane in order.dropLast() {
            let shown = try #require(remounted.panes[pane], "pane \(pane) did not mount again").view.stripView.restorableScrollOffset
            #expect(abs(shown - (strips[pane] ?? 0)) < 0.5, "pane \(pane)'s tab strip rests at \(shown), not \(strips[pane] ?? 0)")
        }
        #expect(abs(remounted.screenBar.view.restorableScrollOffset - bar) < 0.5,
                "the screen bar rests at \(remounted.screenBar.view.restorableScrollOffset), not \(bar)")
        // A pane the layout does not have leaves the record: one that closed for good is never carried.
        #expect(remounted.viewRecord().tabStrips[late] == nil, "a pane outside the layout stayed in the record")

        // It comes back: it mounts at its saved offset.
        store.apply(snapshot: Self.crowdedTree())
        remounted.applyCurrent()
        remounted.contentView.layoutSubtreeIfNeeded()
        let lateStrip = try #require(remounted.panes[late], "the returning pane did not mount").view.stripView
        #expect(abs(lateStrip.restorableScrollOffset - (strips[late] ?? 0)) < 0.5,
                "the pane mounted after the remount rests at \(lateStrip.restorableScrollOffset), not \(strips[late] ?? 0)")
    }

    // MARK: The window's unmount and remount

    /// Workspace `k0`: one pane of 40 tabs (its strip overflows); `k1`: one pane of one tab.
    private static func windowTree() -> DaemonTree {
        let crowded = PaneSnapshot(id: DaemonPaneID(rawValue: 1),
                                   tabs: (0..<40).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64(100 + $0)), title: "~") })
        let single = PaneSnapshot(id: DaemonPaneID(rawValue: 2), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 2), title: "~")])
        let screens = [ScreenSnapshot(id: DaemonScreenID(rawValue: 1), layout: .leaf(crowded.id), panes: [crowded]),
                       ScreenSnapshot(id: DaemonScreenID(rawValue: 2), layout: .leaf(single.id), panes: [single])]
        let keys = ["k0", "k1"]
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screens[index]])
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        return tree
    }

    @Test(.timeLimit(.minutes(1)))
    func aWindowShowsAWorkspaceItReleasedUnderMemoryPressureAsItWas() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.windowTree())
        let state = WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"view-record","workspace_key":"k0"}"#.utf8)))
        services.windows.registry.provisional[state.id] = ["k0", "k1"]
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        // A host without a display clamps a new window to its minimum size: set the frame outright.
        controller.window?.setFrame(NSRect(x: 200, y: 200, width: 1100, height: 720), display: false)
        controller.showWorkspace(requested: state.workspaceID)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let first = try #require(controller.content)
        #expect(first.workspace.id == "k0")
        let pane = try #require(first.panes.keys.first)
        let offset = try Self.scrollHalfway(try #require(first.panes[pane]).view.stripView)

        // Another workspace shows: k0 parks, then a critical-pressure release slice tears it down.
        state.showWorkspace("k1")
        controller.showWorkspace(requested: state.workspaceID)
        #expect(controller.parked["k0"] === first)
        #expect(controller.discardParkedWorkspace("k0"))
        #expect(controller.parked["k0"] == nil, "the parked workspace stayed mounted")
        #expect(controller.unmountedViews["k0"]?.tabStrips[pane] == offset, "the release kept no record of k0's strip")

        // k0 shows again: a new mount, at the saved offset from the first layout pass, and the record is spent.
        state.showWorkspace("k0")
        controller.showWorkspace(requested: state.workspaceID)
        #expect(controller.unmountedViews["k0"] == nil, "the remount left its record behind")
        let shown = try #require(controller.content)
        #expect(shown !== first && shown.workspace.id == "k0")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let restored = try #require(shown.panes[pane], "k0's pane did not mount again").view.stripView.restorableScrollOffset
        #expect(abs(restored - offset) < 0.5, "k0's tab strip rests at \(restored), not \(offset)")
    }
}

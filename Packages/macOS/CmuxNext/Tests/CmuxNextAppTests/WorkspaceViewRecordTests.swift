import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextLayout
import Foundation
import Testing

/// A workspace its window unmounts (`WindowController.releaseParked`) comes back as it was
/// (p07-memory-033): its `WorkspaceViewRecord` keeps the strip scroll, each pane's selected tab and
/// tab strip scroll, the focused pane and the screen bar scroll, and the next mount applies it
/// before its first frame commits. The record stays at most 2 KB for 12 panes.
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
        state.reduce(.sync(Self.strip(viewport: 0), focused: LayoutPaneID("p2"), source: .programmatic, animated: false))
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
        state.reduce(.sync(Self.strip(viewport: 1210), focused: LayoutPaneID("p0"), source: .programmatic, animated: false))
        #expect(state.spring.target == 0)
    }

    @Test func aSavedCameraPastTheStripIsClamped() {
        var state = ColumnScrollState()
        state.pendingRestore = 9000
        state.reduce(.sync(Self.strip(viewport: 1210), focused: LayoutPaneID("p5"), source: .programmatic, animated: false))
        #expect(state.spring.target == Self.strip(viewport: 1210).maxOffset)
    }

    // MARK: The record

    @Test func aTwelvePaneRecordRoundTripsInAtMostTwoKilobytes() throws {
        var record = WorkspaceViewRecord(focusedPane: UUID().uuidString.lowercased(), screenBar: 212.5)
        record.screens[UUID().uuidString.lowercased()] = .init(strip: 3660, rows: [UUID().uuidString.lowercased(): 480], areas: [:])
        for _ in 0..<12 {
            record.panes[UUID().uuidString.lowercased()] = .init(tab: UUID().uuidString.lowercased(), strip: 96.5)
        }
        let data = try JSONEncoder().encode(record)
        #expect(data.count <= 2048, "a 12-pane record is \(data.count) bytes")
        #expect(try JSONDecoder().decode(WorkspaceViewRecord.self, from: data) == record)
    }

    @Test func anUnscrolledStripRecordsNothing() {
        #expect(WorkspaceViewRecord.stripOffset(0) == nil)
        #expect(WorkspaceViewRecord.stripOffset(120) == 120)
    }

    // MARK: Unmount and remount

    /// Twelve half-width columns, one pane each, two tabs per pane.
    private static func tree() -> DaemonTree {
        let panes = (1...12).map { index in
            PaneSnapshot(id: DaemonPaneID(rawValue: UInt64(index)),
                         tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(2 * index)), title: "~"),
                                TabSnapshot(surface: SurfaceID(rawValue: UInt64(2 * index + 1)), title: "~")])
        }
        let columns = (1...12).map { index in
            ColumnSnapshot(id: DaemonColumnID(rawValue: UInt64(100 + index)), width: 0.5, layout: .leaf(DaemonPaneID(rawValue: UInt64(index))))
        }
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"view-record-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    private static func windowState() throws -> WindowState {
        WindowState(record: try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8)))
    }

    /// Installs `content` in `window` and lays it out: the layout pass before the first frame.
    private static func mount(_ content: WorkspaceContentController, in window: NSWindow) {
        content.contentView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        window.contentView = content.contentView
        content.contentView.layoutSubtreeIfNeeded()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRemountedWorkspaceShowsTheScrollAndSelectionItWasUnmountedWith() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let workspace = try #require(store.workspaces.first)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Each controller holds its window state unowned: the test keeps both alive, as a window does.
        let first = try Self.windowState(), second = try Self.windowState()
        let mounted = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: first)
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
        var saved = mounted.viewRecord()
        let (screen, scroll) = try #require(saved.screens.first)
        let strip = try #require(scroll.strip)
        // Revealing the seventh column put its right edge at the viewport's. The person then scrolled
        // 400 pt further (it still shows): a mount that dropped the record would reveal it at the edge again.
        #expect(strip > 0, "the strip did not scroll to the seventh column")
        saved.screens[screen]?.strip = strip + 400
        #expect(!saved.panes.isEmpty && saved.panes.values.allSatisfy { $0.tab != nil })
        mounted.teardown()

        // Another window state: nothing of the first mount's selection or focus memory is shared.
        let remounted = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: second,
                                                   restoring: saved)
        defer { withExtendedLifetime((services, first, second)) { remounted.teardown(); window.close() } }
        remounted.layoutModel.centerFocusedColumnOverride = .never
        remounted.layoutModel.focus(far, notify: false)
        remounted.layoutView.syncWithModel()
        Self.mount(remounted, in: window)

        // The first layout pass (before the first frame) already shows the saved camera.
        let shown = try #require(remounted.layoutView.frame(of: far))
        #expect(shown.maxX < 1000, "the seventh column shows at \(shown), not 400 pt left of the viewport's edge")
        let restored = remounted.viewRecord()
        #expect(restored.screens == saved.screens, "the remount's offsets differ: \(restored.screens) vs \(saved.screens)")
        for (pane, record) in saved.panes {
            #expect(second.selection.selection(in: pane) == record.tab, "pane \(pane) lost its selected tab")
            if let controller = remounted.panes[LayoutPaneID(pane)] {
                #expect(controller.stripModel.selectedID?.rawValue == record.tab, "pane \(pane) shows another tab")
            }
        }
    }
}

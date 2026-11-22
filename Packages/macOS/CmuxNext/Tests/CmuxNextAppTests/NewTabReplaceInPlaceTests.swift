import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-10-13: the terminal or browser a New Tab page opens appears where it will live. It
/// grew in at the end of the strip, the page's tab shrank away a frame later, and then the new
/// tab slid back from the end into the page's slot once its move landed: three motions for one
/// replace, one of them from an unrelated place. The new tab now takes the page's cell from its
/// first frame, and the page's tab leaves with it.
@Suite(.closesItsWindows)
@MainActor struct NewTabReplaceInPlaceTests {
    private static func tree(_ surfaces: [UInt64]) -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: surfaces.map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"replace-in-place-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// One frame of the strip: where the new tab's cell is, and whether the page's cell still shows.
    struct Frame: CustomStringConvertible {
        var new: CGRect?
        var page: CGRect?
        var description: String {
            let new = self.new.map { "new x=\(Int($0.minX)) w=\(Int($0.width))" } ?? "new -"
            return page.map { "\(new), page x=\(Int($0.minX)) w=\(Int($0.width))" } ?? new
        }
    }

    @Test func whatANewTabPageOpensTakesThePagesTabInPlace() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        // A terminal, the New Tab page, another terminal.
        store.apply(snapshot: Self.tree([1, 2, 3]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let page = try #require(store.tab(surface: SurfaceID(rawValue: 2)))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        window.contentView = pane.view
        window.orderFrontRegardless()
        state.selection.select(page.id, in: pane.paneKey)
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let strip = pane.view.stripView
        let pageFrame = try #require(strip.cells[TabID(page.id)]?.layer.frame, "the page's tab is not in the strip")

        // The page opens a terminal (NewTabPage.replace): it reads the page's slot first...
        let placed = NewTabSlot.placing(replacing: page.id, onMachine: MachineRegistry.localID, services: services, then: nil)
        // ...the daemon makes the terminal at the end of the pane, and the app selects it.
        store.apply(snapshot: Self.tree([1, 2, 3, 4]))
        let made = SurfaceID(rawValue: 4)
        let new = try #require(store.tab(surface: made))
        pane.selectWhenReported(surface: made)
        placed?(made)

        var frames: [Frame] = []
        func sample() { frames.append(Frame(new: strip.cells[TabID(new.id)]?.layer.frame, page: strip.cells[TabID(page.id)]?.layer.frame)) }
        sample()
        let start = ContinuousClock.now
        var closed = false, moved = false
        while ContinuousClock.now < start.advanced(by: .milliseconds(500)) {
            try await Task.sleep(for: .milliseconds(4))
            let elapsed = ContinuousClock.now - start
            // A frame later the page closes; the move into its slot lands after a daemon round trip.
            if !closed, elapsed > .milliseconds(16) {
                store.apply(snapshot: Self.tree([1, 3, 4]))
                closed = true
            }
            if !moved, elapsed > .milliseconds(80) {
                store.apply(snapshot: Self.tree([1, 4, 3]))
                moved = true
            }
            sample()
        }

        let shown = frames.compactMap(\.new)
        #expect(frames.first?.new != nil, "the new tab did not show when it was selected: \(frames.prefix(3))")
        #expect(shown.allSatisfy { abs($0.minX - pageFrame.minX) <= 1 && abs($0.width - pageFrame.width) <= 1 },
                "the new tab did not take the page's cell (x=\(Int(pageFrame.minX)) w=\(Int(pageFrame.width))): \(frames)")
        #expect(!frames.contains { $0.new != nil && $0.page != nil }, "the page's tab stayed beside its replacement: \(frames)")
    }

    /// Cmd-T's New Tab page shows as a provisional tab until the store has its tab, which then
    /// replaces it in one step under another id: the strip shrank the provisional tab while the
    /// store's tab grew in beside it. The store's tab takes the provisional tab's cell.
    @Test func theStoresTabTakesTheProvisionalNewTabPagesCell() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1, 2]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        window.contentView = pane.view
        window.orderFrontRegardless()
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        // Cmd-T (AgentTabStore.open): the provisional New Tab page shows and is selected now.
        let provisional = ProvisionalTab()
        var page = TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id),
                               kind: .conversation, title: "about:blank", browserRenderer: "frontend")
        page.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: nil, harness: nil))
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: model.handle, provisional: page), transaction: transaction)
        pane.selectWhenReported(surface: provisional.surface)
        let strip = pane.view.stripView
        // Where the provisional tab's cell is when the store answers (its grow-in may still run).
        let cell = try #require(strip.cells[TabID(provisional.id)]?.layer.frame, "the provisional New Tab page is not in the strip")

        // The store answers: its tab replaces the provisional one, and the selection follows it.
        let made = SurfaceID(rawValue: 3)
        ProvisionalTab.created(transaction, surface: made, in: store)
        store.apply(snapshot: Self.tree([1, 2, 3]))
        let real = try #require(store.tab(surface: made))
        pane.selectWhenReported(surface: made)

        var frames: [Frame] = []
        let start = ContinuousClock.now
        while ContinuousClock.now < start.advanced(by: .milliseconds(300)) {
            frames.append(Frame(new: strip.cells[TabID(real.id)]?.layer.frame, page: strip.cells[TabID(provisional.id)]?.layer.frame))
            try await Task.sleep(for: .milliseconds(4))
        }
        let shown = frames.compactMap(\.new)
        #expect(!shown.isEmpty, "the store's tab never showed")
        // It goes on from the provisional cell: same place, never narrower (a grow-in carries on).
        #expect(shown.first.map { abs($0.width - cell.width) <= 1 } == true && shown.allSatisfy { abs($0.minX - cell.minX) <= 1 }
                    && zip(shown, shown.dropFirst()).allSatisfy { $1.width >= $0.width - 1 },
                "the store's tab did not take the provisional tab's cell (x=\(Int(cell.minX)) w=\(Int(cell.width))): \(frames)")
        #expect(!frames.contains { $0.new != nil && $0.page != nil }, "the provisional tab stayed beside the store's tab: \(frames)")
    }

    /// New Tab to the Right: the daemon makes the tab at the end of the pane and it moved into its
    /// slot when the move landed, sliding across the strip. It grows in at its slot instead.
    @Test func aTabOpenedToTheRightGrowsInAtItsSlot() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree([1, 2, 3]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let anchor = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let neighbour = try #require(store.tab(surface: SurfaceID(rawValue: 2)))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        window.contentView = pane.view
        window.orderFrontRegardless()
        state.selection.select(anchor.id, in: pane.paneKey)
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let strip = pane.view.stripView
        let slot = try #require(strip.cells[TabID(neighbour.id)]?.layer.frame, "the anchor's neighbour is not in the strip")

        // New Tab to the Right of the first tab: the daemon makes it at the end, the app selects it.
        let placed = NewTabSlot.placing(after: anchor, services: services, then: nil as (@MainActor (SurfaceID) -> Void)?)
        store.apply(snapshot: Self.tree([1, 2, 3, 4]))
        let made = SurfaceID(rawValue: 4)
        let new = try #require(store.tab(surface: made))
        pane.selectWhenReported(surface: made)
        placed?(made)

        var xs: [CGFloat?] = []
        let start = ContinuousClock.now
        var moved = false
        while ContinuousClock.now < start.advanced(by: .milliseconds(400)) {
            xs.append(strip.cells[TabID(new.id)]?.layer.frame.minX)
            try await Task.sleep(for: .milliseconds(4))
            // The move into its slot lands after a daemon round trip.
            if !moved, ContinuousClock.now - start > .milliseconds(80) {
                store.apply(snapshot: Self.tree([1, 4, 2, 3]))
                moved = true
            }
        }
        #expect(xs.first.flatMap { $0 } != nil, "the new tab did not show when it was selected")
        #expect(xs.compactMap { $0 }.allSatisfy { abs($0 - slot.minX) <= 1 },
                "the new tab did not grow in at its slot (x=\(Int(slot.minX))): \(xs.map { $0.map { Int($0) } })")
    }
}

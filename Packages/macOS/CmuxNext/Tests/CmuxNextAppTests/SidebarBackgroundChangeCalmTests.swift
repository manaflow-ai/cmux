import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Lawrence 2026-10-20 (calm-sidebar-movement): "my sidebar is moving too much and it shows me the
/// animation when it moves. It distracts me." A model change nobody in this window asked for (an
/// agent's status, a workspace an agent made or grouped, another client) shows in place with no
/// spring, and waits while the pointer is over the rows; the user's own changes still move.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarBackgroundChangeCalmTests {
    /// The local machine's section with the workspaces `ids`, in that order.
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// `sections` with the first section's rows in `order` (indices into its rows).
    private static func reordered(_ sections: [CmuxNextSidebar.SidebarSection], _ order: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        var result = sections
        let rows = sections[0].workspaces
        result[0] = CmuxNextSidebar.SidebarSection(kind: sections[0].kind, nodes: order.map { .workspace(rows[$0]) })
        return result
    }

    /// A sidebar in a window; `onScreen` orders it front, so Motion may animate in it.
    private static func sidebar(_ model: SidebarModel, height: CGFloat = 600, onScreen: Bool) -> (SidebarView, NSWindow) {
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: height)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        if onScreen { window.orderFrontRegardless() }
        sidebar.layoutSubtreeIfNeeded()
        // The first render draws the selection; the changes under test come after it.
        sidebar.renderNow()
        sidebar.list.reload(animated: false, fromModel: true)
        return (sidebar, window)
    }

    /// The workspace rows still moving right after the change: a row on the render server's spring
    /// (`RowMotion.animate`) has its frame at the slot and an additive position spring on its layer; a
    /// row a frame write left off its slot, or still fading in, moves too.
    private static func rowMotion(in list: SidebarListView) -> [String] {
        list.displayed.rows.compactMap { row -> String? in
            guard case .workspace = row.key, let view = list.rowViews[row.key] else { return nil }
            let target = list.frame(for: row)
            let springs = view.layer.map { layer in
                (layer.animationKeys() ?? []).contains { key in
                    (layer.animation(forKey: key) as? CASpringAnimation).map { $0.isAdditive && $0.keyPath == "position" } ?? false
                }
            } ?? false
            return springs || abs(view.frame.minY - target.minY) > 0.5 || view.alphaValue < 0.99
                ? "\(row.key) at \(view.frame.minY), slot \(target.minY)\(springs ? ", springing" : "")" : nil
        }
    }

    /// The workspace ids in the order the list draws them.
    private static func drawnOrder(_ list: SidebarListView) -> [CmuxNextSidebar.WorkspaceID] {
        list.displayed.rows.compactMap { if case let .workspace(id) = $0.key { id } else { nil } }
    }

    @Test(.enabled("needs an awake display and animations on, or every change snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aReorderNobodyAskedForMovesNoRow() throws {
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: start)
        let (sidebar, window) = Self.sidebar(model, onScreen: true)
        defer { window.close() }
        try #require(window.screen != nil)
        sidebar.list.pointerIsOverList = { _ in false }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        // An agent's activity puts workspace 4 first: the daemon's new order arrives, nobody here asked.
        model.sections = Self.reordered(start, [3, 0, 1, 2])
        sidebar.renderNow()

        #expect(Self.drawnOrder(sidebar.list) == model.sections[0].workspaces.map(\.id), "the new order did not show")
        #expect(Self.rowMotion(in: sidebar.list).isEmpty, "rows slid for a change nobody asked for: \(Self.rowMotion(in: sidebar.list))")
    }

    @Test(.enabled("needs an awake display and animations on, or every change snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aReorderTheUserAskedForStillMoves() throws {
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: start)
        let (sidebar, window) = Self.sidebar(model, onScreen: true)
        defer { window.close() }
        try #require(window.screen != nil)
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }

        // Move to Top from the palette: the user's run marks the sidebar, its change arrives after.
        model.noteUserIntent()
        model.sections = Self.reordered(start, [3, 0, 1, 2])
        sidebar.renderNow()

        #expect(!Self.rowMotion(in: sidebar.list).isEmpty, "the user's own Move to Top did not move its rows")
    }

    @Test func aChangeNobodyAskedForWaitsWhileThePointerIsOverTheRows() throws {
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: start)
        let (sidebar, window) = Self.sidebar(model, onScreen: false)
        defer { window.close() }
        let list = sidebar.list
        let before = Self.drawnOrder(list)
        let frames = before.map { list.rowViews[.workspace($0)]?.frame }
        var pointerOver = true
        list.pointerIsOverList = { _ in pointerOver }

        model.sections = Self.reordered(start, [3, 0, 1, 2])
        sidebar.renderNow()
        #expect(Self.drawnOrder(list) == before, "rows reordered under the pointer")
        #expect(before.map { list.rowViews[.workspace($0)]?.frame } == frames, "a row moved under the pointer")

        // The pointer leaves the list: the change shows, in one step.
        pointerOver = false
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 0, userData: nil))
        list.mouseExited(with: exit)
        #expect(Self.drawnOrder(list) == model.sections[0].workspaces.map(\.id), "the held change did not show when the pointer left")
    }

    @Test func theUsersOwnChangeShowsUnderThePointer() {
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: start)
        let (sidebar, window) = Self.sidebar(model, onScreen: false)
        defer { window.close() }
        sidebar.list.pointerIsOverList = { _ in true }

        model.noteUserIntent()
        model.sections = Self.reordered(start, [3, 0, 1, 2])
        sidebar.renderNow()
        #expect(Self.drawnOrder(sidebar.list) == model.sections[0].workspaces.map(\.id), "the user's own change waited")
    }

    @Test func theUsersMarkRunsOut() {
        let model = SidebarModel(sections: Self.sections([1]))
        var now = ContinuousClock.now
        model.userIntentClock = { now }
        #expect(!model.followsUserIntent)
        model.noteUserIntent()
        #expect(model.followsUserIntent)
        now = now.advanced(by: SidebarModel.userIntentWindow + .milliseconds(1))
        #expect(!model.followsUserIntent, "a change long after the user's request still counted as theirs")
    }

    @Test func aWorkspaceAddedAboveTheViewportKeepsTheShownRowsStill() throws {
        let all = Array(1...40)
        let start = Self.sections(all)
        let ids = try #require(start.first?.workspaces.map(\.id))
        let model = SidebarModel(sections: start, activeWorkspaceID: ids[30])
        let (sidebar, window) = Self.sidebar(model, height: 320, onScreen: false)
        defer { window.close() }
        let list = sidebar.list
        list.pointerIsOverList = { _ in false }
        let clip = try #require(list.enclosingScrollView?.contentView)
        let top = try #require(list.displayed.row(for: .workspace(ids[19])))
        list.scrollClip(to: top.y, animated: false)
        let shownBefore = try #require(list.displayed.row(for: .workspace(ids[19]))).y - clip.bounds.minY

        // Another client makes workspace 0 at the top of the list.
        model.sections = Self.sections([0] + all)
        sidebar.renderNow()
        let shownAfter = try #require(list.displayed.row(for: .workspace(ids[19]))).y - clip.bounds.minY
        #expect(abs(shownAfter - shownBefore) < 0.5, "the shown rows jumped by \(shownAfter - shownBefore) pt")
    }
}

import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import QuartzCore
import Testing

/// What one space switch makes the sidebar list and the window do, counted: the rows the list lays out, the row
/// frames it computes, the row views it configures and makes, and the views and layers of the window that changed
/// (new, gone, moved, resized, hidden or shown) from before the switch to after its layout, display and flush.
/// A switch shows a window's height of rows, so each count must stay at what is shown: one that grows with the
/// session is work the frame of the switch waits for. The list laid out every row of the space on each switch
/// (`SidebarLayout.make`), also on a switch back to a space whose rows did not change.
/// The size is the one argument: 20, 60 and 826 workspaces (826 is the count of the session the budget is for),
/// half in each space, one pane with two tabs in each. Run this suite alone: the sidebar's counters are per process.
@MainActor @Suite(.serialized)
struct SpaceSwitchListWorkTests {
    @Test(arguments: [20, 60, 826])
    func aSwitchBackLaysOutNoRowAgain(_ total: Int) async throws {
        let bench = try await SpaceSwitchBench(total: total, panes: true, registered: true)
        defer { bench.close() }
        // Each space shown once: its rows are mapped, laid out and parked.
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        settle(bench)
        for round in 0..<6 {
            let before = WindowCensus(bench.controller.window)
            let counters = try await bench.settledSwitch(to: bench.rooms[(round + 1) % 2])
            settle(bench)
            let after = WindowCensus(bench.controller.window)
            let count = { (name: String) in counters[name] ?? 0 }
            print("SPACE-SWITCH-LIST-WORK n=\(total) switch=\(round) listed_rows=\(bench.list.displayed.rows.count) "
                + "layout_rows=\(count("layout_rows")) row_frames=\(count("row_frames")) row_configures=\(count("row_configures")) "
                + "row_views_made=\(count("row_views_made")) list_subviews=\(bench.list.subviews.count) "
                + "views=\(after.views.count) views_changed=\(after.changedViews(from: before)) "
                + "layers=\(after.layers.count) layers_changed=\(after.changedLayers(from: before))")
            #expect(count("layout_rows") == 0,
                    "switch \(round) at \(total) workspaces: the list laid out \(count("layout_rows")) rows for a space whose rows did not change")
        }
    }

    /// A row whose title changed while its space was hidden: the switch back shows the new title and lays out no
    /// row for it (one row's content changed, no row moved: the cost is that row's, not the space's).
    @Test func aSwitchBackToARenamedRowShowsTheNewTitleAndLaysOutNoRow() async throws {
        let bench = try await SpaceSwitchBench(total: 20, panes: true, registered: true)
        defer { bench.close() }
        let store = bench.services.machines.local.store
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        settle(bench)
        var live = bench.tree
        for round in 0..<3 {
            _ = try await bench.settledSwitch(to: bench.rooms[1])
            settle(bench)
            // Workspace 4 ("k4") is in the first space, which is hidden now.
            live.workspaces[4].name = "Agent step \(round)"
            store.apply(snapshot: live)
            store.advanceAppliedSequence(to: store.appliedSequence + 1)
            #expect(bench.services.workspace(id: "k4")?.name == "Agent step \(round)", "the snapshot of round \(round) did not apply")
            settle(bench)
            let counters = try await bench.settledSwitch(to: bench.rooms[0])
            settle(bench)
            let id = WorkspaceID("k4")
            let laidOut = counters["layout_rows"] ?? 0
            print("SPACE-SWITCH-LIST-WORK renamed round=\(round) layout_rows=\(laidOut) row_patches=\(counters["row_patches"] ?? 0) "
                + "title=\(bench.list.workspaces[id]?.title ?? "nil")")
            #expect(bench.list.displayed.row(for: .workspace(id)) != nil, "round \(round): the renamed row is not listed")
            #expect(bench.list.workspaces[id]?.title == "Agent step \(round)", "round \(round): the list draws the row's old title")
            let drawn = (bench.list.rowViews[.workspace(id)] as? WorkspaceRowView)?.title.stringValue
            #expect(drawn == "Agent step \(round)", "round \(round): the row's view shows \(drawn ?? "no view")")
            #expect(laidOut == 0, "round \(round): the list laid out \(laidOut) rows for one row's new title")
        }
    }

    /// A workspace closed while its space was hidden has no row after the switch back, and the other rows of the
    /// space are listed (a structural change of a hidden space shows in the frame of the switch).
    @Test func aWorkspaceClosedWhileItsSpaceWasHiddenHasNoRowAfterTheSwitchBack() async throws {
        let bench = try await SpaceSwitchBench(total: 20, panes: true, registered: true)
        defer { bench.close() }
        let store = bench.services.machines.local.store
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        settle(bench)
        _ = try await bench.settledSwitch(to: bench.rooms[1])
        settle(bench)
        let closed = WorkspaceKey(rawValue: "k4")
        var live = bench.tree
        live.workspaces.removeAll { $0.key == closed }
        live.personal?.pins.removeAll { $0.workspaceKey == closed }
        live.personal?.workspaces.removeAll { $0.workspaceKey == closed }
        store.apply(snapshot: live)
        store.advanceAppliedSequence(to: store.appliedSequence + 1)
        #expect(bench.services.workspace(id: "k4") == nil, "the snapshot without the workspace did not apply")
        settle(bench)
        _ = try await bench.settledSwitch(to: bench.rooms[0])
        settle(bench)
        let listed = bench.list.displayed.rows.compactMap { row -> String? in
            if case let .workspace(id) = row.key { id.rawValue } else { nil }
        }
        print("SPACE-SWITCH-LIST-WORK closed listed=\(listed.count)")
        #expect(!listed.contains("k4"), "the closed workspace still has a row")
        #expect(Set(listed) == ["k0", "k2", "k6", "k8", "k10", "k12", "k14", "k16", "k18"], "the rows of the space after the close: \(listed)")
    }

    /// A group folded in a space, then open again when the space shows again (another window opened it, or the daemon
    /// refused the fold, while the space was hidden): the switch back shows the group's members. A fold changes the
    /// layout the list shows in place, so the page the list keeps must hold the same fold in its sections; with the
    /// open group in them it took the folded layout for the layout of the open group.
    @Test func aGroupOpenedWhileItsSpaceWasHiddenShowsItsMembersAfterTheSwitchBack() throws {
        typealias Fixture = SidebarIncrementalMatchesRebuildTests
        let (sidebar, window) = Fixture.fixture(Fixture.Doc())
        defer { window.close() }
        let list = sidebar.list, model = list.model
        let (first, second) = (ProfileKey("space-a"), ProfileKey("space-b"))
        model.profiles = [SidebarProfile(id: first, name: "A"), SidebarProfile(id: second, name: "B")]
        model.activeProfileID = first
        list.reload(animated: false, fromModel: true)
        sidebar.renderNow()
        let open = model.sections
        let members = try #require(model.group(Fixture.work)?.workspaces.map(\.id), "the fixture has no group")
        try #require(!members.isEmpty && members.allSatisfy { list.displayed.row(for: .workspace($0)) != nil }, "the open group does not list its members")
        // This fixture reaches the kept page: a switch away and back with no change lays out no row.
        func show(_ sections: [CmuxNextSidebar.SidebarSection], in space: ProfileKey) -> Int {
            model.sections = sections
            model.activeProfileID = space
            _ = SidebarPerfCounters.report(reset: true)
            sidebar.renderNow()
            return SidebarPerfCounters.report(reset: true)["layout_rows"] ?? 0
        }
        _ = show([], in: second)
        let plain = show(open, in: first)
        #expect(plain == 0, "a switch back with no change laid out \(plain) rows: this fixture does not take the kept page")
        model.setGroupCollapsed(Fixture.work, true)
        sidebar.renderNow()
        try #require(members.contains { list.displayed.row(for: .workspace($0)) == nil }, "the fold hides no member")
        _ = show([], in: second)
        // The model's sections of the first space when it shows again: the group is open.
        let laidOut = show(open, in: first)
        let hidden = members.filter { list.displayed.row(for: .workspace($0)) == nil }
        print("SPACE-SWITCH-LIST-WORK fold plain_layout_rows=\(plain) layout_rows=\(laidOut) hidden_members=\(hidden.count)")
        #expect(hidden.isEmpty, "the open group shows no row for \(hidden.map(\.rawValue)): the list shows the folded layout it kept")
    }

    /// A row moved, then a change the list draws in place (a row patch, or a group's fold), in one turn (one batch of
    /// a script or of the daemon), then a switch away in that turn, before the reload that shows the move: the switch
    /// back shows the model's order. The patch and the fold write the model's section into the list's row caches, so
    /// a page kept from those caches and the layout of the old order compared equal to the model, and the list took
    /// the old order for the new one.
    @Test(arguments: ["patch", "fold"])
    func aChangeDrawnInPlaceBeforeAMoveShowsLeavesNoPageOfTheOldOrder(_ change: String) throws {
        typealias Fixture = SidebarIncrementalMatchesRebuildTests
        let (sidebar, window) = Fixture.fixture(Fixture.Doc())
        defer { window.close() }
        let list = sidebar.list, model = list.model
        let (first, second) = (ProfileKey("space-a"), ProfileKey("space-b"))
        model.profiles = [SidebarProfile(id: first, name: "A"), SidebarProfile(id: second, name: "B")]
        model.activeProfileID = first
        list.reload(animated: false, fromModel: true)
        sidebar.renderNow()
        let (scratch, loose) = (WorkspaceID("scratch"), WorkspaceID("loose2"))
        func order() -> [String] {
            list.displayed.rows.compactMap { row -> String? in
                if case let .workspace(id) = row.key, id == scratch || id == loose { id.rawValue } else { nil }
            }
        }
        func show(_ sections: [CmuxNextSidebar.SidebarSection], in space: ProfileKey) -> Int {
            model.sections = sections
            model.activeProfileID = space
            _ = SidebarPerfCounters.report(reset: true)
            sidebar.renderNow()
            return SidebarPerfCounters.report(reset: true)["layout_rows"] ?? 0
        }
        func node(_ id: WorkspaceID, in nodes: [CmuxNextSidebar.SidebarNode]) -> Int? {
            nodes.firstIndex { if case let .workspace(row) = $0 { row.id == id } else { false } }
        }
        let before = model.sections
        try #require(order() == ["scratch", "loose2"], "the fixture's two loose rows are \(order())")
        _ = show([], in: second)
        let plain = show(before, in: first)
        #expect(plain == 0, "a switch back with no change laid out \(plain) rows: this fixture does not take the kept page")
        // The model moves "loose2" over "scratch" and takes a new title for it; no reload shows the move.
        var moved = before
        let at = try #require(moved.firstIndex { node(loose, in: $0.nodes) != nil }, "no section lists the loose row")
        let from = try #require(node(loose, in: moved[at].nodes)), to = try #require(node(scratch, in: moved[at].nodes))
        moved[at].nodes.swapAt(from, to)
        model.sections = moved
        if change == "patch" {
            var renamed = try #require(list.workspaces[loose], "the list holds no content for the loose row")
            renamed.title = "Renamed"
            try #require(model.patchWorkspaces([renamed]), "the model refused the row patch")
        } else {
            try #require(model.setGroupCollapsed(Fixture.work, true), "the model has no group to fold")
        }
        let live = model.sections
        try #require(order() == ["scratch", "loose2"], "the list showed the move before the switch: \(order())")
        _ = show([], in: second)
        let laidOut = show(live, in: first)
        print("SPACE-SWITCH-LIST-WORK moved change=\(change) plain_layout_rows=\(plain) layout_rows=\(laidOut) order=\(order())")
        #expect(order() == ["loose2", "scratch"], "the list shows \(order()): the order of the page it kept, not the model's")
    }

    /// The window's pending layout, display and Core Animation work, done now.
    private func settle(_ bench: SpaceSwitchBench) {
        bench.controller.window?.contentView?.layoutSubtreeIfNeeded()
        bench.controller.window?.displayIfNeeded()
        CATransaction.flush()
        bench.drain()
    }
}

/// Every view and every layer of a window at one time, each with its place and whether it is hidden. The census
/// holds the objects, so one freed between two counts is never taken for a new one at its address.
@MainActor
private struct WindowCensus {
    struct Mark: Equatable {
        var frame: CGRect
        var isHidden: Bool
    }

    private(set) var views: [ObjectIdentifier: Mark] = [:]
    private(set) var layers: [ObjectIdentifier: Mark] = [:]
    private var held: [AnyObject] = []

    init(_ window: NSWindow?) {
        guard let root = window?.contentView?.superview ?? window?.contentView else { return }
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            views[ObjectIdentifier(view)] = Mark(frame: view.frame, isHidden: view.isHidden)
            held.append(view)
            pending.append(contentsOf: view.subviews)
        }
        var layersPending: [CALayer] = root.layer.map { [$0] } ?? []
        while let layer = layersPending.popLast() {
            layers[ObjectIdentifier(layer)] = Mark(frame: layer.frame, isHidden: layer.isHidden)
            held.append(layer)
            layersPending.append(contentsOf: layer.sublayers ?? [])
        }
    }

    /// Views new, gone, moved, resized, hidden or shown since `old`.
    func changedViews(from old: WindowCensus) -> Int { Self.changed(views, from: old.views) }

    /// Layers new, gone, moved, resized, hidden or shown since `old`.
    func changedLayers(from old: WindowCensus) -> Int { Self.changed(layers, from: old.layers) }

    private static func changed(_ new: [ObjectIdentifier: Mark], from old: [ObjectIdentifier: Mark]) -> Int {
        new.count(where: { old[$0.key] != $0.value }) + old.keys.count(where: { new[$0] == nil })
    }
}

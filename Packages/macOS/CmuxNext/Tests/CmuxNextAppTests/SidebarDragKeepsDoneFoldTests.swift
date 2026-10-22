import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21 (ask-13d9bbd5e3): "have we fixed this dragging workspace sidebar things hiding random groups? and
/// also preventing unnecessary multi-sidebar walks to reposition stuff when moving things around". A drag unfolded
/// every "Done (N)" row (#23633): at the lift the Done rows vanished, every Done workspace showed in its place and the
/// rows below moved down, then the drop folded them again and the rows moved back. A drag keeps the folds: the only
/// row that leaves its place is the dragged one, and the drop shows the order the drag showed.
@MainActor @Suite(.serialized) struct SidebarDragKeepsDoneFoldTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let section = SectionID.machine(.local)
    static let group = GroupID("g")

    static func ws(_ id: String, done: Bool = false) -> SidebarWorkspace {
        var row = SidebarWorkspace(id: WorkspaceID(id), title: id)
        if done { row.taskStatus = .done }
        return row
    }

    /// Loose a, b (done), c, d (done), e; then group g: g1 (done), g2, g3 (done), g4.
    static func sections() -> [SidebarSection] {
        let group = SidebarGroup(id: group, name: "G", color: .green,
                                 workspaces: [ws("g1", done: true), ws("g2"), ws("g3", done: true), ws("g4")])
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("a")), .workspace(ws("b", done: true)), .workspace(ws("c")), .workspace(ws("d", done: true)),
            .workspace(ws("e")), .group(group),
        ])]
    }

    static let doneIDs: Set<WorkspaceID> = Set(["b", "d", "g1", "g3"].map(WorkspaceID.init))

    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel(sections: sections(), activeWorkspaceID: WorkspaceID("e"))
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 700))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    static func keys(_ list: SidebarListView) -> Set<SidebarRowKey> {
        Set(list.displayed.rows.map(\.key).filter { if case .section = $0 { false } else { true } })
    }

    static func shownDone(_ list: SidebarListView) -> [WorkspaceID] {
        list.displayed.rows.compactMap { if case let .workspace(id) = $0.key, doneIDs.contains(id) { id } else { nil } }
    }

    /// Drags `a` to the top, then down past the last row, a few points per frame: every frame draws the same rows
    /// (the two Done rows too), never a folded workspace; the drop draws the order the last frame showed.
    @Test func aDragKeepsTheDoneRowsFoldedOnEveryFrame() throws {
        // `sidebar.doneFold` on (its default), whatever another suite left in the store.
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.doneFold.key, .bool(true))
        defer { TunableStore.shared.set(SidebarTunables.doneFold.key, nil) }
        let (list, window) = Self.list()
        defer { window.close() }
        let dragged = SidebarRowKey.workspace(WorkspaceID("a"))
        let before = Self.keys(list)
        try #require(before.contains(.doneFold(SidebarDoneFoldID(section: Self.section, group: nil))), "no loose Done row: \(before)")
        try #require(before.contains(.doneFold(SidebarDoneFoldID(section: Self.section, group: Self.group))), "no group Done row: \(before)")
        try #require(Self.shownDone(list).isEmpty, "the fold draws Done workspaces before the drag")

        let row = try #require(list.displayed.row(for: dragged))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: dragged, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "a did not lift")

        var failures: [String] = []
        func check(_ step: String) {
            let shown = Self.keys(list)
            if shown != before { failures.append("\(step): rows \(shown.subtracting(before)) added, \(before.subtracting(shown)) gone") }
            let done = Self.shownDone(list)
            if !done.isEmpty { failures.append("\(step): folded workspaces drawn \(done)") }
        }
        check("lift")
        let bottom = (list.displayed.rows.last?.maxY ?? 600) + 10
        var y = start.y, frame = 0
        for target in [CGFloat(4), bottom] {
            let dy: CGFloat = target < y ? -6 : 6
            while (dy < 0 && y > target) || (dy > 0 && y < target) {
                y += dy
                frame += 1
                list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
                check("frame \(frame) at y \(Int(y)) (target \(String(describing: list.drag?.target)))")
            }
        }
        let previewed = list.displayed.rows.map(\.key).filter { if case .section = $0 { false } else { true } }
        list.finishDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        check("drop")
        let dropped = list.displayed.rows.map(\.key).filter { if case .section = $0 { false } else { true } }
        #expect(dropped == previewed, "the drop drew \(dropped), the drag showed \(previewed)")
        #expect(failures.isEmpty, "\(failures.prefix(12).joined(separator: "\n"))")
    }

    /// A drop gap (a tab from a pane, a tile) at a model index the fold hides opens before the next drawn row, or
    /// before the Done row when no drawn row follows: where the dropped row will show.
    @Test func aGapAtAFoldedIndexOpensWhereTheRowWillShow() throws {
        func layout(_ gap: DropPosition) -> SidebarLayout {
            var o = SidebarLayoutOptions()
            o.foldsDone = true
            o.gap = gap
            o.gapHeight = 30
            return SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: o)
        }
        func gapAbove(_ layout: SidebarLayout, _ key: SidebarRowKey) throws -> Bool {
            let gapY = try #require(layout.gapY, "no gap opened")
            let row = try #require(layout.row(for: key), "no row \(key)")
            return abs(row.y - (gapY + layout.gapHeight + SidebarLayoutMetrics.standard.rowSpacing)) < 0.5
        }
        let loose = SidebarDoneFoldID(section: Self.section, group: nil)
        let grouped = SidebarDoneFoldID(section: Self.section, group: Self.group)
        // Loose b (index 1) is folded: the gap opens before c (index 2), the next drawn row.
        #expect(try gapAbove(layout(DropPosition(section: Self.section, index: 1)), .workspace(WorkspaceID("c"))))
        // d (index 3): before e.
        #expect(try gapAbove(layout(DropPosition(section: Self.section, index: 3)), .workspace(WorkspaceID("e"))))
        // In the group, g1 (0): before g2; g3 (2): before g4.
        #expect(try gapAbove(layout(DropPosition(section: Self.section, group: Self.group, index: 0)), .workspace(WorkspaceID("g2"))))
        #expect(try gapAbove(layout(DropPosition(section: Self.section, group: Self.group, index: 2)), .workspace(WorkspaceID("g4"))))
        // A drawn index still opens before its row; the end of the group's list opens after its last drawn member, before its Done row.
        #expect(try gapAbove(layout(DropPosition(section: Self.section, index: 2)), .workspace(WorkspaceID("c"))))
        #expect(try gapAbove(layout(DropPosition(section: Self.section, group: Self.group, index: 4)), .doneFold(grouped)))
        // A gap at a folded index with no drawn row after it opens before the Done row.
        var sections = Self.sections()
        sections[0].nodes[5] = .group(SidebarGroup(id: Self.group, name: "G", color: .green,
                                                   workspaces: [Self.ws("g2"), Self.ws("g3", done: true)]))
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        o.gap = DropPosition(section: Self.section, group: Self.group, index: 1)
        o.gapHeight = 30
        let folded = SidebarLayout.make(sections: sections, metrics: .standard, options: o)
        #expect(try gapAbove(folded, .doneFold(grouped)), "the gap at g3's folded index did not open before the Done row")
        // The loose list's end: before its Done row too.
        #expect(try gapAbove(layout(DropPosition(section: Self.section, index: 6)), .doneFold(loose)))
    }

    /// A loose `x`, then an open group `g` with `members` and nothing after it, laid out with the Done rows folded.
    static func groupAtEnd(_ members: [SidebarWorkspace], tabs: Bool = false) -> ([SidebarSection], SidebarLayout) {
        let sections = [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("x")), .group(SidebarGroup(id: group, name: "G", color: .green, workspaces: members)),
        ])]
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        o.showWorkspaceTabs = tabs
        return (sections, SidebarLayout.make(sections: sections, metrics: .standard, options: o))
    }

    /// Where the older (Rust) resolver drops `x` with the pointer at `y`.
    static func resolve(_ y: CGFloat, _ sections: [SidebarSection], _ layout: SidebarLayout) -> DropTarget? {
        DropResolver.resolve(y: y, payload: .workspaces([WorkspaceID("x")]), base: layout, sections: sections)
    }

    /// The older resolver reads a group that a Done row ends as it would with no fold: the bottom of its last drawn
    /// member, of that member's tab rows, of the Done row and of the space below leaves the group (Codex review).
    @Test func aDropBelowAGroupThatADoneRowEndsLeavesTheGroup() throws {
        let after = DropTarget.position(DropPosition(section: Self.section, group: nil, index: 2))
        let fold = SidebarRowKey.doneFold(SidebarDoneFoldID(section: Self.section, group: Self.group))
        // A drawn member, then a folded one.
        var (sections, layout) = Self.groupAtEnd([Self.ws("g2"), Self.ws("d", done: true)])
        var done = try #require(layout.row(for: fold), "no Done row")
        #expect(Self.resolve(done.maxY - 1, sections, layout) == after, "over the Done row: \(String(describing: Self.resolve(done.maxY - 1, sections, layout)))")
        #expect(Self.resolve(done.maxY + 40, sections, layout) == after, "below the group")
        // The drawn member's upper half still drops before it, in the group.
        let g2 = try #require(layout.row(for: .workspace(WorkspaceID("g2"))))
        #expect(Self.resolve(g2.y + 2, sections, layout) == .position(DropPosition(section: Self.section, group: Self.group, index: 0)))
        // The last drawn member lists its tabs: the tab rows are part of it, so below them leaves the group too.
        var tabbed = Self.ws("g2")
        tabbed.tabs = [SidebarTab(id: TabID("t1"), title: "t1"), SidebarTab(id: TabID("t2"), title: "t2")]
        (sections, layout) = Self.groupAtEnd([tabbed, Self.ws("d", done: true)], tabs: true)
        try #require(layout.row(for: .tab(WorkspaceID("g2"), TabID("t2"))) != nil, "the layout lists no tab rows")
        done = try #require(layout.row(for: fold))
        #expect(Self.resolve(done.maxY - 1, sections, layout) == after, "over the Done row under tab rows")
        // Every member is Done: the header alone stands for the group, so its bottom and below leave it.
        (sections, layout) = Self.groupAtEnd([Self.ws("d1", done: true), Self.ws("d2", done: true)])
        done = try #require(layout.row(for: fold))
        #expect(Self.resolve(done.maxY - 1, sections, layout) == after, "over an all-Done group's Done row")
    }

    /// An open fold draws its Done rows below the fold row, out of model order: a gap at a Done row's index opens
    /// above the fold, before the first row after it in model order, where the new (never Done) row will show.
    @Test func aGapAtAnOpenFoldsDoneIndexOpensAboveTheFold() throws {
        let loose = SidebarDoneFoldID(section: Self.section, group: nil)
        let sections = [SidebarSection(kind: .machine(Self.machine), nodes: [
            .workspace(Self.ws("a")), .workspace(Self.ws("b", done: true)), .workspace(Self.ws("c")),
        ])]
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        o.openDoneFolds = [loose]
        o.gapHeight = 30
        o.gap = DropPosition(section: Self.section, index: 1)
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: o)
        let keys = layout.rows.map(\.key).filter { if case .section = $0 { false } else { true } }
        try #require(keys == [.workspace(WorkspaceID("a")), .workspace(WorkspaceID("c")), .doneFold(loose), .workspace(WorkspaceID("b"))],
                     "drawn: \(keys)")
        let gapY = try #require(layout.gapY, "no gap opened")
        let c = try #require(layout.row(for: .workspace(WorkspaceID("c"))))
        #expect(abs(c.y - (gapY + layout.gapHeight + SidebarLayoutMetrics.standard.rowSpacing)) < 0.5, "the gap is not above c")
    }
}

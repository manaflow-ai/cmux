import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-21 (ask-13d9bbd5e3): "have we fixed this dragging workspace sidebar things hiding random groups? and
/// also preventing unnecessary multi-sidebar walks to reposition stuff when moving things around". A drag unfolded
/// every "Done (N)" row (#23633): at the lift the Done rows vanished, every Done workspace showed in its place and the
/// rows below moved down, then the drop folded them again and the rows moved back. A drag keeps the folds: the only
/// row that leaves its place is the dragged one, and the drop shows the order the drag showed.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragKeepsDoneFoldTests {
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
    static func groupAtEnd(_ members: [SidebarWorkspace], open: Bool = false) -> ([SidebarSection], SidebarLayout) {
        let sections = [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("x")), .group(SidebarGroup(id: group, name: "G", color: .green, workspaces: members)),
        ])]
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        if open { o.openDoneFolds = [SidebarDoneFoldID(section: section, group: group)] }
        return (sections, SidebarLayout.make(sections: sections, metrics: .standard, options: o))
    }

    /// Where the older (Rust) resolver drops `x` with the pointer at `y`.
    static func resolve(_ y: CGFloat, _ sections: [SidebarSection], _ layout: SidebarLayout) -> DropTarget? {
        DropResolver.resolve(y: y, payload: .workspaces([WorkspaceID("x")]), base: layout, sections: sections)
    }

    /// The older resolver reads a group that a Done row ends as it would with no fold: the bottom of its last drawn
    /// member, of the Done row and of the space below leaves the group (Codex review).
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
        // Every member is Done: the header alone stands for the group, so its bottom and below leave it.
        (sections, layout) = Self.groupAtEnd([Self.ws("d1", done: true), Self.ws("d2", done: true)])
        done = try #require(layout.row(for: fold))
        #expect(Self.resolve(done.maxY - 1, sections, layout) == after, "over an all-Done group's Done row")
        // The fold open: its Done workspace, drawn last, ends the group, so below it leaves the group.
        (sections, layout) = Self.groupAtEnd([Self.ws("g1"), Self.ws("d", done: true), Self.ws("g2")], open: true)
        let keys = layout.rows.map(\.key).filter { if case .section = $0 { false } else { true } }
        try #require(keys.suffix(2) == [fold, .workspace(WorkspaceID("d"))], "drawn: \(keys)")
        let d = try #require(layout.row(for: .workspace(WorkspaceID("d"))))
        #expect(Self.resolve(d.maxY + 40, sections, layout) == after, "below the open fold's group")
    }

    @Test func anExternalTabDragKeepsItsUnfoldedResolverGeometry() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        list.external = SidebarListView.ExternalDrag(windowPoint: .zero, sourceMachine: .local)
        #expect(!list.options(includeGap: false).foldsDone)
    }

    /// Codex review: a group's drag slides its "Done (N)" row with it: the row is part of the lifted group (one level
    /// in, like its members), so the slot the drag maps the pointer through spans it on every frame.
    @Test func aGroupDragCarriesItsDoneRow() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.doneFold.key, .bool(true))
        defer { TunableStore.shared.set(SidebarTunables.doneFold.key, nil) }
        let (list, window) = Self.list()
        defer { window.close() }
        let fold = SidebarRowKey.doneFold(SidebarDoneFoldID(section: Self.section, group: Self.group))
        let header = try #require(list.displayed.row(for: .group(Self.group)))
        try #require(list.displayed.row(for: fold) != nil, "no group Done row")
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: .group(Self.group), point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag, "the group did not lift")
        #expect(drag.hiddenKeys.contains(fold), "the group's Done row does not lift with it: \(drag.hiddenKeys)")
        var y = start.y, failures: [String] = []
        while y > 4 {
            y -= 6
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
            guard let gapY = list.displayed.gapY, let row = list.displayed.row(for: fold) else { continue }
            if row.y < gapY || row.maxY > gapY + list.displayed.gapShift { failures.append("y \(Int(y)): Done row outside the slot") }
        }
        list.cancelDrag()
        #expect(failures.isEmpty, "\(failures.prefix(8).joined(separator: "\n"))")
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

    /// Codex review: with the loose fold open, `a` and `d` (Done) selected and dragged together would draw `a` in its
    /// place and `d` below the fold, with `b` and the fold row between them, while the drag maps the pointer through one
    /// slot from the first dragged row to the last. A drag that carries a Done row unfolds (as before), so every frame
    /// draws the dragged rows together and the drop lands where the pointer left them.
    @Test func aDragThatCarriesADoneRowDrawsItsRowsTogether() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.doneFold.key, .bool(true))
        defer { TunableStore.shared.set(SidebarTunables.doneFold.key, nil) }
        let loose = SidebarDoneFoldID(section: Self.section, group: nil)
        _ = NSApplication.shared
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(Self.machine), nodes: [
            .workspace(Self.ws("a")), .workspace(Self.ws("d", done: true)), .workspace(Self.ws("b")), .workspace(Self.ws("e", done: true)),
        ])], activeWorkspaceID: WorkspaceID("a"))
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 500))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.openDoneFolds = [loose]
        list.reload(animated: false)
        let drawn = list.displayed.rows.map(\.key).filter { if case .section = $0 { false } else { true } }
        try #require(drawn == [.workspace(WorkspaceID("a")), .workspace(WorkspaceID("b")), .doneFold(loose),
                               .workspace(WorkspaceID("d")), .workspace(WorkspaceID("e"))], "drawn: \(drawn)")
        model.selection = [WorkspaceID("a"), WorkspaceID("d")]

        let dragged: Set<SidebarRowKey> = [.workspace(WorkspaceID("a")), .workspace(WorkspaceID("d"))]
        let row = try #require(list.displayed.row(for: .workspace(WorkspaceID("a"))))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: .workspace(WorkspaceID("a")), point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "a and d did not lift")
        var failures: [String] = []
        func check(_ step: String) {
            let keys = list.displayed.rows.sorted { $0.y < $1.y }.map(\.key)
            guard let first = keys.firstIndex(where: dragged.contains), let last = keys.lastIndex(where: dragged.contains) else { return }
            let between = keys[first...last].filter { !dragged.contains($0) }
            if !between.isEmpty { failures.append("\(step): \(between) drawn between the dragged rows") }
        }
        check("lift")
        let bottom = (list.displayed.rows.last?.maxY ?? 400) + 10
        var y = start.y, frame = 0
        while y < bottom {
            y += 6
            frame += 1
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
            check("frame \(frame) at y \(Int(y))")
        }
        list.finishDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        let order = model.sections.first?.nodes.map(\.id) ?? []
        #expect(order == ["b", "e", "a", "d"].map { SidebarNode.ID.workspace(WorkspaceID($0)) }, "dropped below e: \(order)")
        #expect(failures.isEmpty, "\(failures.prefix(12).joined(separator: "\n"))")

        // Which drags unfold: those that carry a row the fold would hide or draw below it (Codex review: a lone Done
        // row dropped into a list with no fold would add a "Done (1)" row the drag's base rows lack).
        var o = SidebarLayoutOptions()
        (o.foldsDone, o.openDoneFolds, o.activeWorkspaceID) = (true, [loose], WorkspaceID("a"))
        #expect(SidebarLayout.dragUnfolds([Self.ws("b"), Self.ws("d", done: true)], options: o), "a mixed drag")
        #expect(SidebarLayout.dragUnfolds([Self.ws("d", done: true)], options: o), "a lone Done row")
        #expect(!SidebarLayout.dragUnfolds([Self.ws("b"), Self.ws("c")], options: o), "no Done row")
        #expect(!SidebarLayout.dragUnfolds([Self.ws("a", done: true), Self.ws("b")], options: o), "the active Done row keeps its place")
        o.openDoneFolds = []
        #expect(SidebarLayout.dragUnfolds([Self.ws("d", done: true)], options: o), "a selected Done row a closed fold hides")
        o.foldsDone = false
        #expect(!SidebarLayout.dragUnfolds([Self.ws("d", done: true)], options: o), "no fold")
    }

    /// A group whose fold hides every workspace but still draws its link, tab or app rows is open: the resolver must
    /// not read its header as folded, or a drop on it appends after the items instead of going to the group's top.
    @Test func aFoldedGroupThatStillDrawsItemsStaysOpenForTheResolver() {
        let fold = SidebarDoneFoldID(section: Self.section, group: Self.group)
        func row(_ key: SidebarRowKey, _ y: CGFloat, group: GroupID?, last: Bool = false) -> SidebarRow {
            SidebarRow(key: key, y: y, height: 24, section: Self.section, group: group, siblingIndex: 0, parentIndex: 0,
                       isLastInGroup: last, isCollapsed: false, childCount: 0)
        }
        func header(_ rows: [SidebarRow]) -> RustRow? {
            RustRow.resolvable(rows).first { $0.key.kind == "group" && $0.key.id == Self.group.rawValue }
        }
        let withItems = [row(.group(Self.group), 0, group: Self.group), row(.item("link"), 24, group: Self.group),
                         row(.doneFold(fold), 48, group: Self.group, last: true)]
        #expect(header(withItems)?.isCollapsed == false, "items still show under the header")
        let noItems = [row(.group(Self.group), 0, group: Self.group), row(.doneFold(fold), 24, group: Self.group, last: true)]
        #expect(header(noItems)?.isCollapsed == true, "a group that draws no member reads as folded")

        // Sol review: a group whose fold hides every workspace but which still draws an open subgroup is open, so a
        // drop on its header's middle still goes into it.
        let sub = GroupID("sub")
        var subHeader = row(.group(sub), 48, group: sub)
        subHeader.depth = 1
        var subMember = row(.workspace(WorkspaceID("s")), 72, group: sub, last: true)
        subMember.depth = 2
        let withSubgroup = [row(.group(Self.group), 0, group: Self.group), row(.doneFold(fold), 24, group: Self.group, last: true),
                            subHeader, subMember]
        #expect(header(withSubgroup)?.isCollapsed == false, "an open subgroup still shows under the header")
        var sibling = row(.group(sub), 48, group: sub)
        sibling.depth = 0
        #expect(header([row(.group(Self.group), 0, group: Self.group), row(.doneFold(fold), 24, group: Self.group, last: true),
                        sibling])?.isCollapsed == true, "a group below at the same level is no subgroup")

        // Codex review: a link drawn below the group's last shown workspace ends the group, so a drop on that
        // workspace's lower edge still inserts within the group instead of leaving it.
        let itemBelow = [row(.group(Self.group), 0, group: Self.group), row(.workspace(WorkspaceID("w")), 24, group: Self.group),
                         row(.item("link"), 48, group: Self.group), row(.doneFold(fold), 72, group: Self.group, last: true)]
        let member = RustRow.resolvable(itemBelow).first { $0.key.kind == "workspace" }
        #expect(member?.isLastInGroup == false, "the link below still belongs to the group")
        let itemAbove = [row(.group(Self.group), 0, group: Self.group), row(.item("link"), 24, group: Self.group),
                         row(.workspace(WorkspaceID("w")), 48, group: Self.group), row(.doneFold(fold), 72, group: Self.group, last: true)]
        #expect(RustRow.resolvable(itemAbove).first { $0.key.kind == "workspace" }?.isLastInGroup == true, "nothing drawn below it")
    }
}

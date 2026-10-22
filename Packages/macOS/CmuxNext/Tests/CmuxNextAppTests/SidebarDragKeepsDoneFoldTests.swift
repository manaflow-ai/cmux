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

    /// Runs `body` with `sidebar.doneFold` on (its default), whatever another suite left in the store.
    static func withDoneFold(_ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.set(SidebarTunables.doneFold.key, .bool(true))
        defer { TunableStore.shared.set(SidebarTunables.doneFold.key, nil) }
        try body()
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
        try Self.withDoneFold {
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

    /// The older resolver's rows leave the Done row out; the group's last drawn member is then its last row, so a
    /// drop past it leaves the group, as with no fold.
    @Test func theLastDrawnMemberBeforeAGroupsDoneRowEndsTheGroupForTheResolver() throws {
        var o = SidebarLayoutOptions()
        o.foldsDone = true
        let layout = SidebarLayout.make(sections: Self.sections(), metrics: .standard, options: o)
        let fold = try #require(layout.row(for: .doneFold(SidebarDoneFoldID(section: Self.section, group: Self.group))))
        #expect(fold.isLastInGroup)
        #expect(layout.row(for: .workspace(WorkspaceID("g4")))?.isLastInGroup == false, "the drawn rows changed")
        let rows = RustRow.resolvable(layout.rows)
        let last = rows.filter { $0.group == Self.group.rawValue && $0.key.kind == "workspace" }.map { ($0.key.id ?? "", $0.isLastInGroup) }
        #expect(last.map(\.0) == ["g2", "g4"])
        #expect(last.map(\.1) == [false, true], "the resolver's last member: \(last)")
    }
}

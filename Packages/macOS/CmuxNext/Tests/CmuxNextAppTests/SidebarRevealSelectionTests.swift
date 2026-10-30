import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-19 (u2605): "Pressing Command-1 or Command-2 doesn't scroll all the way
/// up, which is an issue right now for the sidebar." Every selection (Cmd-1…9, Cmd-Ctrl-[ / ],
/// the palette, the CLI, a click) reveals the row that stands for it through one path, and the
/// reveal shows the row's context: the group or section header right above it, the list's top
/// padding when nothing selectable lies above it, the bottom padding when nothing lies below it.
/// A top item the list draws inside a block (the sidebar document's Pinned/top section) is a
/// selection the list reveals too.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarRevealSelectionTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func ws(_ n: Int) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID("ws-\(n)"), title: "w\(n)") }
    static func id(_ n: Int) -> WorkspaceID { WorkspaceID("ws-\(n)") }

    /// One machine section with `nodes`.
    static func sections(_ nodes: [SidebarNode]) -> [CmuxNextSidebar.SidebarSection] {
        [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)]
    }

    static func loose(_ range: ClosedRange<Int>) -> [SidebarNode] { range.map { .workspace(ws($0)) } }

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        var list: SidebarListView { sidebar.list }

        init(sections: [CmuxNextSidebar.SidebarSection], active: WorkspaceID?, layout: SidebarLayoutDocument? = nil) {
            model = SidebarModel(sections: sections, activeWorkspaceID: active)
            if let layout {
                model.layout = layout
                model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in },
                                               adoptRef: { _ in nil })
            }
            sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 320)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
        }

        var clip: NSClipView { list.enclosingScrollView!.contentView }
        var offset: CGFloat { clip.bounds.minY }
        var maxOffset: CGFloat { max(0, list.displayed.totalHeight - clip.bounds.height) }

        func scroll(to y: CGFloat) {
            list.scrollClip(to: min(max(0, y), maxOffset), animated: false)
        }

        func select(_ id: WorkspaceID) {
            model.apply(.select(id))
            sidebar.renderNow()
        }

        func row(_ key: SidebarRowKey) throws -> SidebarRow { try #require(list.displayed.row(for: key), "no row \(key)") }

        /// Whether `key`'s row lies wholly inside the viewport.
        func shows(_ key: SidebarRowKey) throws -> Bool {
            let row = try row(key)
            return row.y >= offset - 0.5 && row.maxY <= clip.bounds.maxY + 0.5
        }
    }

    init() { Motion.reduceMotionOverride = true }

    @Test func cmd1FromTheBottomScrollsAllTheWayToTheTop() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(sections: Self.sections(Self.loose(1...40)), active: Self.id(40))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        h.scroll(to: h.maxOffset)
        try #require(h.offset > 100)
        h.select(Self.id(1))
        #expect(abs(h.offset) < 0.5, "Cmd-1 left the list at \(h.offset), not at its top")
    }

    @Test func cmd1WithTheTopPaddingCutOffScrollsToTheTop() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(sections: Self.sections(Self.loose(1...40)), active: Self.id(2))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        // The first row is still wholly in view, only the padding above it is cut.
        h.scroll(to: 3)
        try #require(try h.shows(.workspace(Self.id(1))))
        h.select(Self.id(1))
        #expect(abs(h.offset) < 0.5, "Cmd-1 kept the list at \(h.offset): the top padding stays cut off")
    }

    @Test func theFirstRowInAGroupShowsItsHeaderAndTheTop() throws {
        defer { Motion.reduceMotionOverride = nil }
        let group = SidebarGroup(id: GroupID("grp-top"), name: "Top", workspaces: (1...3).map(Self.ws))
        let h = Harness(sections: Self.sections([.group(group)] + Self.loose(4...40)), active: Self.id(40))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        h.scroll(to: h.maxOffset)
        h.select(Self.id(1))
        #expect(try h.shows(.group(GroupID("grp-top"))), "the group header above the first workspace stayed hidden")
        #expect(abs(h.offset) < 0.5, "Cmd-1 into the first group left the list at \(h.offset), not at its top")
    }

    @Test func aRowInACollapsedGroupShowsItsHeader() throws {
        defer { Motion.reduceMotionOverride = nil }
        let group = SidebarGroup(id: GroupID("grp-mid"), name: "Mid", isCollapsed: true, workspaces: (11...14).map(Self.ws))
        let h = Harness(sections: Self.sections(Self.loose(1...10) + [.group(group)] + Self.loose(15...50)), active: Self.id(50))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        h.scroll(to: h.maxOffset)
        h.select(Self.id(12))
        #expect(try h.shows(.workspace(Self.id(12))), "the selected member of a collapsed group is out of view")
        #expect(try h.shows(.group(GroupID("grp-mid"))), "the collapsed group's header above its shown member stayed hidden")
    }

    @Test func theFirstRowOfAnExpandedGroupShowsItsHeader() throws {
        defer { Motion.reduceMotionOverride = nil }
        let group = SidebarGroup(id: GroupID("grp-open"), name: "Open", workspaces: (11...14).map(Self.ws))
        let h = Harness(sections: Self.sections(Self.loose(1...10) + [.group(group)] + Self.loose(15...50)), active: Self.id(50))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        h.scroll(to: h.maxOffset)
        h.select(Self.id(11))
        #expect(try h.shows(.workspace(Self.id(11))))
        #expect(try h.shows(.group(GroupID("grp-open"))), "the header of the group whose first member was selected stayed hidden")
    }

    @Test func theLastRowShowsTheListsEnd() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(sections: Self.sections(Self.loose(1...40)), active: Self.id(1))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        h.select(Self.id(40))
        #expect(try h.shows(.workspace(Self.id(40))))
        #expect(abs(h.offset - h.maxOffset) < 0.5, "the last row's bottom padding stayed cut off (offset \(h.offset), end \(h.maxOffset))")
    }

    @Test func everySelectionInALongListIsInViewAndTheFirstIsAtTheTop() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = Harness(sections: Self.sections(Self.loose(1...150)), active: Self.id(1))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        for n in [150, 1, 75, 2, 149, 76, 1] {
            h.select(Self.id(n))
            #expect(try h.shows(.workspace(Self.id(n))), "workspace \(n) of 150 is out of view after its selection")
            if n == 1 { #expect(abs(h.offset) < 0.5, "selecting the first of 150 left the list at \(h.offset)") }
        }
    }

    /// Cmd-1 or Cmd-2 pressed again on the workspace it already selected, after the user scrolled the
    /// list away (Lawrence 2026-10-19: "the second time nothing is highlighted"): the row stays selected
    /// and scrolls back into view (`SidebarView.revealSelection`, what `SidebarNavigation` runs on a
    /// repeat press), ungrouped and as a group's member.
    @Test(arguments: [(false, 1), (false, 2), (true, 1), (true, 2)])
    func pressingTheSameNumberTwiceKeepsTheRowSelectedAndRevealsIt(_ grouped: Bool, _ n: Int) throws {
        defer { Motion.reduceMotionOverride = nil }
        let nodes: [SidebarNode] = grouped
            ? [.group(SidebarGroup(id: GroupID("grp-twice"), name: "Twice", workspaces: (1...3).map(Self.ws)))] + Self.loose(4...40)
            : Self.loose(1...40)
        let h = Harness(sections: Self.sections(nodes), active: Self.id(40))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        let key = SidebarRowKey.workspace(Self.id(n))
        h.select(Self.id(n))
        #expect(h.list.selectedRowKey == key, "the first press drew \(String(describing: h.list.selectedRowKey)) selected")
        h.scroll(to: h.maxOffset)
        // The second press: the same selection again, then the shared reveal.
        h.model.apply(.select(Self.id(n)))
        h.sidebar.revealSelection()
        #expect(h.model.selectedItem == .workspace(Self.id(n)), "the second press changed the selection to \(String(describing: h.model.selectedItem))")
        #expect(h.list.selectedRowKey == key, "the second press drew \(String(describing: h.list.selectedRowKey)) selected")
        #expect(try h.shows(key), "the second press left workspace \(n) out of view")
        // The group's first member brings its header (and the list's top) along; a later member is shown alone.
        if grouped && n == 1 { #expect(try h.shows(.group(GroupID("grp-twice"))), "the second press left the group header out of view") }
    }

    /// Cmd-1 / Cmd-2 pick the top items first (SidebarItemOrder); on the sidebar document they draw in a block at the
    /// list's top. Selecting one scrolls the list up to it, as a workspace does.
    @Test func cmd1OnATopItemInTheListsBlockScrollsToTheTop() throws {
        defer { Motion.reduceMotionOverride = nil }
        let home = LayoutItemID("itm_home"), store = LayoutItemID("itm_app_store")
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                                items: [LayoutItem(id: home, ref: SidebarLayoutDocument.homeRef),
                                        LayoutItem(id: store, ref: .app("cmux/app-store"))])
        let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue)), nodes: [])
        let h = Harness(sections: [block] + Self.sections(Self.loose(1...40)), active: Self.id(40),
                        layout: SidebarLayoutDocument(sections: [top]))
        defer { h.window.close() }
        try #require(h.clip.bounds.height > 0)
        try #require(h.list.displayed.row(for: .block(SidebarLayoutDocument.topSectionID.rawValue)) != nil, "the list draws no top block")
        h.scroll(to: h.maxOffset)
        try #require(h.offset > 100)
        h.model.selectedItem = .topItem(store)
        h.sidebar.renderNow()
        #expect(abs(h.offset) < 0.5, "Cmd-2 on a top item left the list at \(h.offset), not at its top")
    }
}

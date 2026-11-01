import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-20 ("unnecessary multi-sidebar walks"): clicking between rows re-laid the sidebar out, and rows
/// jumped, then settled. A click or a selection moves no row, and a move changes the order once, to where it
/// lands. Manual order is the truth; attention order lives only in the Priority view.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarClickMovesNoRowTests {
    private static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    private static func ws(_ id: String) -> CmuxNextSidebar.SidebarWorkspace {
        CmuxNextSidebar.SidebarWorkspace(id: WorkspaceID(id), title: id)
    }

    /// The local machine's section with the workspaces `ids`, in that order (the daemon's rows).
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: machine)
    }

    /// `sections` with the first section's rows in `order` (indices into its rows).
    private static func reordered(_ sections: [CmuxNextSidebar.SidebarSection], _ order: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        var result = sections
        let rows = sections[0].workspaces
        result[0] = CmuxNextSidebar.SidebarSection(kind: sections[0].kind, nodes: order.map { .workspace(rows[$0]) })
        return result
    }

    /// A sidebar in a window that is never ordered front, so nothing animates.
    private static func sidebar(_ model: SidebarModel) -> (SidebarView, NSWindow) {
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.list.reload(animated: false, fromModel: true)
        return (sidebar, window)
    }

    /// Each drawn row's top, by key.
    private static func tops(_ list: SidebarListView) -> [SidebarRowKey: CGFloat] {
        Dictionary(list.displayed.rows.map { ($0.key, $0.y) }, uniquingKeysWith: { first, _ in first })
    }

    private static func drawnOrder(_ list: SidebarListView) -> [WorkspaceID] {
        list.displayed.rows.compactMap { if case let .workspace(id) = $0.key { id } else { nil } }
    }

    /// A collapsed group draws its selected member as its one row. Selecting a row outside it used to drop that
    /// row, so every row below it, the clicked one too, moved up under the pointer.
    @Test func selectingARowOutsideACollapsedGroupMovesNoRow() {
        let group = SidebarGroup(id: GroupID("g"), name: "g", color: .purple, isCollapsed: true, workspaces: [Self.ws("b1"), Self.ws("b2")])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(Self.machine), nodes: [.workspace(Self.ws("a")), .group(group), .workspace(Self.ws("c")), .workspace(Self.ws("d"))]),
        ], activeWorkspaceID: WorkspaceID("b1"))
        let (sidebar, window) = Self.sidebar(model)
        defer { window.close() }
        let before = Self.tops(sidebar.list)
        #expect(before[.workspace(WorkspaceID("b1"))] != nil, "the collapsed group does not draw its selected member")

        model.selectedItem = .workspace(WorkspaceID("c"))
        sidebar.renderNow()
        #expect(Self.tops(sidebar.list) == before, "a click moved rows: \(before) became \(Self.tops(sidebar.list))")
        #expect(sidebar.list.selectedRowKey == .workspace(WorkspaceID("c")))

        model.selectedItem = .workspace(WorkspaceID("a"))
        sidebar.renderNow()
        #expect(Self.tops(sidebar.list) == before, "a second click moved rows")

        // A later full layout (any structural set) draws the same rows: the group keeps the member it showed.
        sidebar.list.reload(animated: false, fromModel: true)
        #expect(Self.tops(sidebar.list) == before, "the next layout dropped the member the group showed")

        // Folding the group again forgets it: only the active row (none here) stays.
        model.setGroupCollapsed(GroupID("g"), false)
        model.setGroupCollapsed(GroupID("g"), true)
        sidebar.list.reload(animated: false, fromModel: true)
        #expect(sidebar.list.displayed.row(for: .workspace(WorkspaceID("b1"))) == nil, "a refolded group still shows the member left behind")
    }

    /// A change nobody asked for that lands in the same turn as a click (an agent's reorder) waits while the
    /// pointer is over the rows, as it does without the click: the click draws its selection only.
    @Test func aClickDoesNotShowAWaitingReorder() throws {
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: start)
        let (sidebar, window) = Self.sidebar(model)
        defer { window.close() }
        let list = sidebar.list
        var pointerOver = true
        list.pointerIsOverList = { _ in pointerOver }
        let before = Self.drawnOrder(list)
        let tops = Self.tops(list)

        let clicked = start[0].workspaces[2].id
        model.selectedItem = .workspace(clicked)
        model.sections = Self.reordered(start, [3, 0, 1, 2])
        sidebar.renderNow()
        #expect(Self.drawnOrder(list) == before, "the click showed a reorder nobody asked for")
        #expect(Self.tops(list) == tops, "a row moved on the click")
        #expect(list.selectedRowKey == .workspace(clicked), "the click did not draw its selection")

        // The pointer leaves: the held reorder shows, in one step.
        pointerOver = false
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 0, userData: nil))
        list.mouseExited(with: exit)
        #expect(Self.drawnOrder(list) == model.sections[0].workspaces.map(\.id), "the held reorder did not show when the pointer left")
    }

    /// A move shows once, at its final order: the pending edit masks the daemon's partial echo (one step of a
    /// several-command placement) and the settle after the store holds it.
    @Test func aMoveChangesTheOrderOnce() {
        let start = Self.sections([1, 2, 3, 4])
        let model = SidebarModel(sections: [])
        let rows = SidebarRows(model: model)
        var orders: [[String]] = []
        func record() {
            let order = model.sections.flatMap(\.workspaces).map(\.title)
            if orders.last != order { orders.append(order) }
        }
        rows.show(start)
        record()
        let moving = [start[0].workspaces[2].id, start[0].workspaces[3].id]
        let edit = rows.edits.add(.reorder(moving, to: DropPosition(section: start[0].id, index: 0)))
        record()
        rows.show(Self.reordered(start, [2, 0, 1, 3])) // the first command's echo
        record()
        rows.show(Self.reordered(start, [2, 3, 0, 1])) // the second's
        record()
        rows.edits.settle(edit)
        record()
        #expect(orders == [["w1", "w2", "w3", "w4"], ["w3", "w4", "w1", "w2"]], "the move showed \(orders.count - 1) order changes: \(orders)")
    }
}

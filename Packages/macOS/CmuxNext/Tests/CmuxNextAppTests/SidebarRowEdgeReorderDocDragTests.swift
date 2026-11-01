import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The row midpoint rule (`SidebarDragGeometry.edgeY`, Lawrence 2026-10-20)
/// through the drag path the app uses: the sidebar document's drag. A real
/// list of loose `w1`, `w2`, `w3` and group `g` (`m1`, `m2`); a row pressed
/// and dragged with `updateDrag`, then the drop's one document move.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarRowEdgeReorderDocDragTests {
    static let section = "sec"

    final class Drops {
        var targets: [SidebarDocTarget] = []
    }

    static func list(_ drops: Drops) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("w1")), .workspace(ws("w2")), .workspace(ws("w3")),
                .group(SidebarGroup(id: GroupID("g"), name: "Group", color: .purple, workspaces: [ws("m1"), ws("m2")])),
            ]),
        ], activeWorkspaceID: WorkspaceID("w1"))
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { _ in section }, begin: { _ in [:] }, drop: { [drops] _, target in drops.targets.append(target) })
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// Workspace `id`'s row in the list as shown now.
    static func row(_ list: SidebarListView, _ id: String) throws -> SidebarRow {
        try #require(list.displayed.row(for: .workspace(WorkspaceID(id))))
    }

    /// Presses workspace `id`'s row, lifts it, then moves the pointer so the card moves by `dy(card)`, in steps.
    static func drag(_ list: SidebarListView, _ id: String, by dy: (_ card: CGRect) throws -> CGFloat) throws {
        let row = try Self.row(list, id)
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: row.key, point: start)
        list.beginDrag(try #require(list.press))
        let card = try #require(list.drag?.lift.frame, "the row did not lift")
        let distance = try dy(card)
        for step in 1...6 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + distance * CGFloat(step) / 6), to: nil))
        }
    }

    static func drop(_ list: SidebarListView) {
        list.finishDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    /// `w3`'s top 1 pt above `w2`'s middle: it goes before `w2` (its centre is still in `w2`'s lower half).
    @Test func aRowMovesUpWhenItsTopPassesTheMiddleAbove() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        let w2 = try Self.row(list, "w2")
        try Self.drag(list, "w3") { card in w2.y + w2.height / 2 - 1 - card.minY }
        Self.drop(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, before: "w_w2")], "drops: \(drops.targets)")
    }

    /// `w1`'s bottom 1 pt below `w2`'s middle: it goes after `w2`.
    @Test func aRowMovesDownWhenItsBottomPassesTheMiddleBelow() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        let w2 = try Self.row(list, "w2")
        try Self.drag(list, "w1") { card in w2.y + w2.height / 2 + 1 - card.maxY }
        Self.drop(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, after: "w_w2")], "drops: \(drops.targets)")
    }

    /// Inside a group: `m2`'s top 1 pt above `m1`'s middle puts it first in the group.
    @Test func aMemberMovesUpInsideItsGroup() throws {
        let drops = Drops()
        let (list, window) = Self.list(drops)
        defer { window.close() }
        let m1 = try Self.row(list, "m1")
        try Self.drag(list, "m2") { card in m1.y + m1.height / 2 - 1 - card.minY }
        Self.drop(list)
        #expect(drops.targets == [SidebarDocTarget(section: Self.section, parent: "g_g", before: "w_m1")], "drops: \(drops.targets)")
    }
}

import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-05 (a recording: claude-sr2-coord, the Coordinators group's one workspace, dragged up out of
/// it): "When I click and drag a workspace on the sidebar, it, like, briefly flickers for a bit." At the
/// drop the emptied group's header left the list by fading where it stood, under the landing card. The card
/// draws no material of its own in a translucent window (#32330), so for the fade both read through each
/// other: "Coordinators" under "claude-sr2-coord", then the header gone. A row that leaves from under a
/// dropped card goes at once; rows elsewhere still fade.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDropUnderCardTests {
    @Test func theEmptiedGroupsHeaderDoesNotFadeUnderTheLandingCard() throws {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let solo = GroupID("Coordinators")
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("workspace-347")),
                .group(SidebarGroup(id: solo, name: "Coordinators", color: .blue, workspaces: [ws("claude-sr2-coord")])),
                .workspace(ws("workspace-330")),
                .workspace(ws("workspace-331")),
            ]),
        ], activeWorkspaceID: WorkspaceID("workspace-347"))
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)

        let dragged = SidebarRowKey.workspace(WorkspaceID("claude-sr2-coord"))
        let header = try #require(list.rowViews[.group(solo)], "no Coordinators header before the drag")
        let row = try #require(list.displayed.row(for: dragged))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: dragged, point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag, "the member did not lift")
        // Up a couple of points a frame until the drop is the loose slot after workspace-347: the header's own
        // place once the group is gone, where the recording's card landed.
        func loose() -> Bool {
            if case let .position(position)? = drag.target { return position.group == nil && position.index == 1 }
            return false
        }
        var y = start.y
        while y > 4, !loose() {
            y -= 2
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
        }
        try #require(loose(), "the drag never offered the slot after workspace-347: \(String(describing: drag.target))")
        list.finishDrag()
        defer { if let landing = list.landing { list.finishLand(landing, then: nil) } }
        #expect(model.group(solo) == nil, "the drop did not empty the group")

        // The card is still on its way to the slot; the header has left the list's rows.
        let card = drag.lift.frame.union(drag.lift.layer?.presentation()?.frame ?? drag.lift.frame)
        let drawn = list.subviews.contains { $0 === header && !$0.isHidden && $0.alphaValue > 0 }
        let fading = list.fadingRows.values.contains { $0 === header } || header.layer?.animation(forKey: "opacity") != nil
        #expect(!(header.frame.intersects(card) && (drawn || fading)),
                "the emptied group's header still draws under the landing card (frame \(header.frame), card \(card), hidden \(header.isHidden), fading \(fading))")
    }
}

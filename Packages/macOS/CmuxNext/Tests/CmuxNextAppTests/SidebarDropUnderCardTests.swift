import AppKit
import Foundation
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
        let model = SidebarModel(sections: Self.sections(grouped: true), activeWorkspaceID: WorkspaceID("workspace-347"))
        let (list, window) = Self.window(model)
        defer { window.close() }
        let solo = GroupID("Coordinators")
        let header = try #require(list.rowViews[.group(solo)], "no Coordinators header before the drag")
        let drag = try Self.dragToHeadersSlot(list)
        list.finishDrag()
        defer { if let landing = list.landing { list.finishLand(landing, then: nil) } }
        #expect(model.group(solo) == nil, "the drop did not empty the group")
        // The card is still on its way to the slot; the header has left the list's rows.
        Self.expectHeaderNotUnder(list, header: header, card: drag.lift)
    }

    /// The app's path: the drop goes to the sidebar document, the list holds the drop's look until the model shows the
    /// move (the settle), and the emptied header leaves in that later reload while the card is still on its way.
    @Test func theEmptiedGroupsHeaderDoesNotFadeUnderTheCardOnADocumentDrop() async throws {
        let store = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: Self.document))
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        _ = NSApplication.shared
        let model = SidebarModel(sections: Self.sections(grouped: true), activeWorkspaceID: WorkspaceID("workspace-347"))
        model.docDrag = SidebarDocDrag(document: store, item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { _ in Self.section }, begin: { items in
            var table: [String: SidebarDocAcceptance] = [Self.section: SidebarDocAcceptance(before: false, into: true, after: false)]
            for id in ["w_workspace-347", "w_workspace-330", "w_workspace-331", "w_claude-sr2-coord"] where !items.contains(id) {
                table[id] = SidebarDocAcceptance(before: true, into: false, after: true)
            }
            table["g_Coordinators"] = SidebarDocAcceptance(before: true, into: true, after: true, refusal: nil)
            return table
        }, drop: { items, target in store.move(items, to: target, title: "Move") })
        let (list, window) = Self.window(model)
        defer { window.close() }
        let solo = GroupID("Coordinators")
        let header = try #require(list.rowViews[.group(solo)], "no Coordinators header before the drag")
        let drag = try Self.dragToHeadersSlot(list)
        list.finishDrag()
        try #require(list.settling != nil, "the drop did not settle on the document's move")
        // The daemon's echo: the group is gone and the workspace stands where its header was.
        list.model.sections = Self.sections(grouped: false)
        list.showModelChange(animates: true)
        defer { if let landing = list.landing { list.finishLand(landing, then: nil) } }
        Self.expectHeaderNotUnder(list, header: header, card: drag.lift)
    }

    static let section = "sec_m_s1"

    static func sections(grouped: Bool) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let coord: SidebarNode = grouped
            ? .group(SidebarGroup(id: GroupID("Coordinators"), name: "Coordinators", color: .blue, workspaces: [ws("claude-sr2-coord")]))
            : .workspace(ws("claude-sr2-coord"))
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws("workspace-347")), coord, .workspace(ws("workspace-330")), .workspace(ws("workspace-331")),
        ])]
    }

    static func window(_ model: SidebarModel) -> (SidebarListView, NSWindow) {
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// Lifts claude-sr2-coord and moves it up a couple of points a frame until the drop is the loose slot after
    /// workspace-347: the header's own place once the group is gone, where the recording's card landed.
    static func dragToHeadersSlot(_ list: SidebarListView) throws -> SidebarListDrag {
        let dragged = SidebarRowKey.workspace(WorkspaceID("claude-sr2-coord"))
        let row = try #require(list.displayed.row(for: dragged))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: dragged, point: start)
        list.beginDrag(try #require(list.press))
        let drag = try #require(list.drag, "the member did not lift")
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
        return drag
    }

    /// The header the drop emptied draws nowhere under the card: not shown, not fading.
    static func expectHeaderNotUnder(_ list: SidebarListView, header: SidebarRowView, card lift: DragLiftView) {
        let card = lift.frame.union(lift.layer?.presentation()?.frame ?? lift.frame)
        let drawn = list.subviews.contains { $0 === header && !$0.isHidden && $0.alphaValue > 0 }
        let fading = list.fadingRows.values.contains { $0 === header } || header.layer?.animation(forKey: "opacity") != nil
        #expect(!(header.frame.intersects(card) && (drawn || fading)),
                "the emptied group's header still draws under the landing card (frame \(header.frame), card \(card), hidden \(header.isHidden), fading \(fading))")
    }

    /// The home daemon's document for `sections(grouped: true)`; its moves never answer (the echo is the test's).
    static let document = Data("""
    {"revision": "1",
     "sections": [{"id": "sec_m_s1", "order": "V", "kind": {"type": "machine", "session_id": "s1"}}],
     "items": [
       {"id": "w_workspace-347", "section": "sec_m_s1", "order": "a", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "workspace-347"}}},
       {"id": "g_Coordinators", "section": "sec_m_s1", "order": "b", "body": {"type": "group", "name": "Coordinators"}},
       {"id": "w_claude-sr2-coord", "section": "sec_m_s1", "parent": "g_Coordinators", "order": "a", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "claude-sr2-coord"}}},
       {"id": "w_workspace-330", "section": "sec_m_s1", "order": "c", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "workspace-330"}}},
       {"id": "w_workspace-331", "section": "sec_m_s1", "order": "d", "body": {"type": "workspace", "ref": {"session_id": "s1", "workspace_id": "workspace-331"}}}
     ]}
    """.utf8)
}

import AppKit
import Testing
@testable import CmuxNextSidebar

/// R77 (Lawrence 2026-10-04): "i dont like sidebar current drag and drop
/// where it has the underlay, ideally it just reorders and animates
/// everything instantly, kinda in place." While a row is dragged, the
/// displayed order already holds it at the drop slot (no placeholder
/// underlay), and on release it settles in that slot with no second jump.
@MainActor @Suite struct SidebarInPlaceReorderTests {
    @Test func theOrderUpdatesDuringTheDragWithNoUnderlayAndNoJumpOnRelease() throws {
        let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
        let sidebar = SidebarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        func order() -> [String] {
            list.displayed.rows.compactMap { row in
                if case let .workspace(ws) = row.key, row.group == nil, row.section == model.sections[1].id { return ws.rawValue }
                return nil
            }
        }
        #expect(order() == ["a", "b", "c"])

        let c = try #require(list.displayed.row(for: .workspace(id("c"))))
        let b = try #require(list.displayed.row(for: .workspace(id("b"))))
        let pressed = NSPoint(x: list.frame(for: c).minX + 40, y: list.frame(for: c).minY + 7)
        list.beginDrag(SidebarListView.Press(key: .workspace(id("c")), point: pressed))
        list.updateDrag(windowPoint: list.convert(NSPoint(x: pressed.x, y: list.frame(for: b).minY + 2), to: nil))

        // The dragged row holds its new slot in the displayed order now.
        #expect(order() == ["a", "c", "b"])
        #expect(list.displayed.gapHeight == 0, "no placeholder underlay")
        let slot = try #require(list.displayed.row(for: .workspace(id("c")))).y

        list.finishDrag()
        #expect(order() == ["a", "c", "b"])
        #expect(try #require(list.displayed.row(for: .workspace(id("c")))).y == slot, "settles in the slot, no second jump")
    }
}

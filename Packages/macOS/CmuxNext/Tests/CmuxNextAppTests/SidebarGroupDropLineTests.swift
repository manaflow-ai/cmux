import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-19 (u2455): "If I drag a workspace group around a little
/// and then I go, the left bar for the color disappears. If I click on a
/// workspace ... it reappears." The group's members' line must show again the
/// moment the dropped (or cancelled) card lands, with no click.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupDropLineTests {
    static let group = GroupID("g-drop-line")

    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("loose-a")),
                .group(SidebarGroup(id: group, name: "Group", color: .purple, workspaces: [ws("m1"), ws("m2")])),
                .workspace(ws("loose-b")),
            ]),
        ], activeWorkspaceID: nil)
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

    /// Drags the group's header `dy` points and lets go (`drop`) or cancels, then lands the card as its flight's end does.
    static func dragGroup(_ list: SidebarListView, dy: CGFloat, drop: Bool) throws {
        let header = try #require(list.displayed.row(for: .group(group)))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        list.press = SidebarPress(key: header.key, point: start)
        list.beginDrag(try #require(list.press))
        #expect(list.groupLineViews.shown[group] == nil, "the line rides on the card while it is lifted")
        for step in 1...4 {
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: start.y + dy * CGFloat(step) / 4), to: nil))
        }
        if drop { list.finishDrag() } else { list.cancelDrag() }
        // The flight's end (without a display the card lands at once, inside the drop).
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(list.landing == nil && list.subviews.contains { $0 is DragLiftView } == false, "the card is still up")
    }

    @Test(arguments: [true, false])
    func theGroupLineShowsAgainWhenTheCardLands(drop: Bool) throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let before = try #require(list.groupLineViews.shown[Self.group], "no group line before the drag")
        #expect(before.alpha == 1 && before.frame.height > 0)

        try Self.dragGroup(list, dy: 6, drop: drop)

        #expect(list.suppressed.isEmpty, "rows still hidden after the landing: \(list.suppressed)")
        let after = try #require(list.groupLineViews.shown[Self.group],
                                 "the group's color line is gone after the \(drop ? "drop" : "cancel") until something reloads the list")
        #expect(after.alpha == 1, "the line is see-through (\(after.alpha))")
        #expect(abs(after.frame.height - before.frame.height) < 0.5 && abs(after.frame.minY - before.frame.minY) < 0.5,
                "the line \(after.frame) is not where it was \(before.frame)")
    }
}

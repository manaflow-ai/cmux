import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-06: "when I make new workspaces sometimes, and, like, I can no longer drag them, or I can only drag them
/// after a super long time". A new workspace's row draws from the press (`SidebarRowState.creating`) and stays that way
/// until the daemon lists the workspace and the sidebar document places it, which can take seconds on a busy daemon.
/// The list refused every press on such a row, so it could not be dragged until then. It still selects nothing, but it
/// drags, and its drop is a reorder the App turns into the create's slot.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarCreatingRowDragTests {
    static func list() -> (SidebarListView, SidebarModel, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let new = SidebarWorkspace(id: WorkspaceID("new"), machineID: .local, title: "new", rowState: .creating)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(ws("x")), .workspace(ws("y")), .workspace(ws("z")), .workspace(new)]),
        ], activeWorkspaceID: WorkspaceID("x"))
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
        return (list, model, window)
    }

    @Test func aRowStillBeingCreatedDragsToTheTopWithoutBeingSelected() throws {
        let (list, model, window) = Self.list()
        defer { window.close() }
        var sent: [SidebarIntent] = []
        model.onIntent = { sent.append($0) }
        list.leftButtonIsDown = { true }
        let start = try SidebarPointerGestureTests.point(list, .workspace(WorkspaceID("new")))
        // The top edge of the first row: above it, not onto it (a drop onto a row groups the two).
        let first = try #require(list.displayed.row(for: .workspace(WorkspaceID("x"))))
        let top = NSPoint(x: start.x, y: first.y + 3)
        list.mouseDown(with: try SidebarPointerGestureTests.event(list, .leftMouseDown, at: start))
        #expect(list.press != nil, "the press on the row being created was dropped")
        #expect(model.activeWorkspaceID == WorkspaceID("x") && !model.selection.contains(WorkspaceID("new")),
                "the press selected a workspace the daemon does not have yet")
        for y in stride(from: start.y - 10, through: top.y, by: -10) {
            list.mouseDragged(with: try SidebarPointerGestureTests.event(list, .leftMouseDragged, at: NSPoint(x: start.x, y: y)))
        }
        list.mouseDragged(with: try SidebarPointerGestureTests.event(list, .leftMouseDragged, at: top))
        #expect(list.drag != nil, "the row being created did not lift")
        list.leftButtonIsDown = { false }
        list.mouseUp(with: try SidebarPointerGestureTests.event(list, .leftMouseUp, at: top))
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        let reorder = sent.compactMap { intent -> (ids: [WorkspaceID], position: DropPosition)? in
            if case let .reorder(ids, position) = intent { return (ids, position) }
            return nil
        }.last
        #expect(reorder?.ids == [WorkspaceID("new")], "the drop sent no reorder of the row being created: \(sent)")
        #expect(reorder?.position.index == 0, "the drop at the top resolved to \(String(describing: reorder?.position))")
        #expect(!sent.contains { if case .select = $0 { true } else { false } }, "the drag selected the row being created: \(sent)")
    }

    @Test func aPlaceholderBarStillNeverDrags() throws {
        let (list, model, window) = Self.list()
        defer { window.close() }
        var sections = model.sections
        sections[0].nodes[3] = .workspace(SidebarWorkspace(id: WorkspaceID("new"), machineID: .local, title: "", rowState: .placeholder))
        model.setSections(sections)
        list.reload(animated: false)
        let start = try SidebarPointerGestureTests.point(list, .workspace(WorkspaceID("new")))
        try SidebarPointerGestureTests.press(list, at: start, moves: [CGVector(dx: 0, dy: -10), CGVector(dx: 0, dy: -40)], release: false)
        #expect(list.drag == nil && list.press == nil, "a placeholder bar lifted")
    }
}

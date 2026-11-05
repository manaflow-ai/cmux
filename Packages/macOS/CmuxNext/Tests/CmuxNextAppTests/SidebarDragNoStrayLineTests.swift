import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Lawrence 2026-10-23: "when dragging workspaces/groups around there is weird blue line". A held drag shows
/// where it drops by the rows making room (the gap, as Finder and Mail do), and by the group header's fill for a
/// drop into a group. Nothing else draws over the rows: no accent line, no dot, no outline, at any step of the
/// drag, and nothing is left after the drop or a cancel.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragNoStrayLineTests {
    static let section = "sec"

    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("w1")), .workspace(ws("w2")), .workspace(ws("w3")),
                .group(SidebarGroup(id: GroupID("g"), name: "Group", color: .purple, workspaces: [ws("m1"), ws("m2")])),
                .group(SidebarGroup(id: GroupID("h"), name: "Other", workspaces: [ws("n1")])),
            ]),
        ], activeWorkspaceID: WorkspaceID("w1"))
        model.docDrag = SidebarDocDrag(item: { key in
            switch key {
            case let .workspace(id): "w_\(id.rawValue)"
            case let .group(group): "g_\(group.rawValue)"
            default: nil
            }
        }, section: { _ in section }, begin: { _ in [:] }, drop: { _, _ in })
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

    /// Every visible stroked or filled shape over the rows that is not a row, the lifted card or a group's rail.
    static func marks(_ list: SidebarListView) -> [String] {
        var found: [String] = []
        func walk(_ layer: CALayer, in owner: String) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            if let shape = layer as? CAShapeLayer, let path = shape.path, !path.isEmpty,
               shape.strokeColor != nil && shape.lineWidth > 0 || shape.fillColor.map({ $0.alpha > 0 }) == true {
                found.append("\(owner): \(path.boundingBox)")
            }
            layer.sublayers?.forEach { walk($0, in: owner) }
        }
        for view in list.subviews where !view.isHidden && view.alphaValue > 0
            && !(view is SidebarRowView) && !(view is DragLiftView) && !(view is GroupLineView) {
            if let layer = view.layer { walk(layer, in: String(describing: type(of: view))) }
        }
        return found
    }

    /// Presses `key`'s row and moves the pointer `dy` in `steps`, checking the marks at every step.
    static func drag(_ list: SidebarListView, _ key: SidebarRowKey, dy: CGFloat, x: CGFloat = 80, steps: Int = 24) throws {
        let row = try #require(list.displayed.row(for: key))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: row.key, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "the row did not lift")
        for step in 1...steps {
            let point = NSPoint(x: x, y: start.y + dy * CGFloat(step) / CGFloat(steps))
            list.updateDrag(windowPoint: list.convert(point, to: nil))
            let marks = Self.marks(list)
            #expect(marks.isEmpty, "step \(step): the drag draws over the rows: \(marks)")
        }
        #expect(list.displayed.gapY != nil, "no gap shows where the drop goes")
    }

    static func end(_ list: SidebarListView, drop: Bool) {
        if drop { list.finishDrag() } else { list.cancelDrag() }
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    /// A workspace dragged down through the loose rows, over both groups' headers and members, then dropped or cancelled.
    @Test(arguments: [true, false])
    func aWorkspaceDragDrawsNoLine(drop: Bool) throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let last = try #require(list.displayed.rows.last)
        try Self.drag(list, .workspace(WorkspaceID("w1")), dy: last.maxY - 20)
        Self.end(list, drop: drop)
        #expect(Self.marks(list).isEmpty, "a mark stays after the \(drop ? "drop" : "cancel"): \(Self.marks(list))")
    }

    /// Pointer at the far left (the outliner's "drag out" x) and at a deep x: no level line either.
    @Test(arguments: [CGFloat(4), 200])
    func aDragAtAnyXDrawsNoLine(x: CGFloat) throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let m2 = try #require(list.displayed.row(for: .workspace(WorkspaceID("m2"))))
        let w2 = try #require(list.displayed.row(for: .workspace(WorkspaceID("w2"))))
        try Self.drag(list, .workspace(WorkspaceID("w2")), dy: m2.maxY - w2.y, x: x)
        Self.end(list, drop: true)
        #expect(Self.marks(list).isEmpty)
    }

    /// A group dragged past the other group: the gap moves, nothing else draws.
    @Test func aGroupDragDrawsNoLine() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let header = try #require(list.displayed.row(for: .group(GroupID("g"))))
        let last = try #require(list.displayed.rows.last)
        try Self.drag(list, .group(GroupID("g")), dy: last.maxY - header.y)
        Self.end(list, drop: false)
        #expect(Self.marks(list).isEmpty)
    }
}

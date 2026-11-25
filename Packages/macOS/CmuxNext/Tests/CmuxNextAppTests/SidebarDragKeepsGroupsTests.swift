import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-20 (two screenshots, during and after a drag): while workspace-31 was dragged, whole
/// collapsed groups ('cmux-next app', 'Glaeda / fleet', 'Scratch', 'Codex') vanished from the list and
/// came back after the drop, and a different row seemed to give way to the dragged one. During a drag
/// every group header stays (collapsed and empty ones are drop targets too), only the dragged row leaves
/// its slot, and nothing else drops out of the list.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarDragKeepsGroupsTests {
    static let groups = ["cmux-next app", "Glaeda / fleet", "Scratch", "Codex", "Open"]

    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        func group(_ name: String, _ members: [String], collapsed: Bool) -> SidebarNode {
            .group(SidebarGroup(id: GroupID(name), name: name, color: .purple, isCollapsed: collapsed, workspaces: members.map(ws)))
        }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("coord-deputy")),
                .workspace(ws("workspace-30")),
                // Collapsed groups with members, and kept groups with no open member (collapsed or not).
                group("cmux-next app", ["a1", "a2"], collapsed: true),
                group("Glaeda / fleet", ["f1"], collapsed: true),
                group("Scratch", [], collapsed: true),
                group("Codex", [], collapsed: false),
                .workspace(ws("workspace-31")),
                group("Open", ["o1", "o2"], collapsed: false),
                .workspace(ws("workspace-32")),
                .workspace(ws("workspace-33")),
            ]),
        ], activeWorkspaceID: WorkspaceID("workspace-31"))
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

    static func headers(_ list: SidebarListView) -> Set<SidebarRowKey> {
        Set(list.displayed.rows.map(\.key).filter(\.isGroupHeader))
    }

    static func workspaceRows(_ list: SidebarListView) -> Set<SidebarRowKey> {
        Set(list.displayed.rows.map(\.key).filter { if case .workspace = $0 { true } else { false } })
    }

    /// Drags workspace-31 up to the top, then down to the bottom, and checks every frame of the drag.
    @Test func everyGroupHeaderAndEveryOtherRowStayWhileARowIsDragged() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let dragged = SidebarRowKey.workspace(WorkspaceID("workspace-31"))
        let headers = Self.headers(list)
        #expect(headers == Set(Self.groups.map { SidebarRowKey.group(GroupID($0)) }), "headers before the drag: \(headers)")
        let others = Self.workspaceRows(list).subtracting([dragged])

        let row = try #require(list.displayed.row(for: dragged))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: dragged, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "workspace-31 did not lift")

        var failures: [String] = []
        func check(_ step: String) {
            let shown = Self.headers(list)
            if shown != headers { failures.append("\(step): headers \(shown.subtracting(headers)) added, \(headers.subtracting(shown)) gone") }
            let missing = others.subtracting(Self.workspaceRows(list))
            if !missing.isEmpty { failures.append("\(step): rows gone \(missing)") }
        }
        check("lift")
        let top: CGFloat = 4, bottom = (list.displayed.rows.last?.maxY ?? 600) + 10
        // Up to the top, then down past the last row, a few points per frame.
        var y = start.y, frame = 0
        for target in [top, bottom] {
            let dy: CGFloat = target < y ? -6 : 6
            while (dy < 0 && y > target) || (dy > 0 && y < target) {
                y += dy
                frame += 1
                list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
                check("frame \(frame) at y \(Int(y)) (target \(String(describing: list.drag?.target)))")
            }
        }
        list.cancelDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(failures.isEmpty, "\(failures.prefix(12).joined(separator: "\n"))")
    }

    /// The last member dragged out of its group: the group's header stays for the whole drag (it is still a drop
    /// target), and the drop's move then drops the emptied group (one change, at the drop).
    @Test func aGroupsLastMemberDraggedOutKeepsTheHeaderUntilTheDrop() throws {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let solo = GroupID("Solo")
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("top")),
                .group(SidebarGroup(id: solo, name: "Solo", color: .green, workspaces: [ws("only")])),
                .workspace(ws("b1")),
                .workspace(ws("b2")),
                .workspace(ws("b3")),
            ]),
        ], activeWorkspaceID: WorkspaceID("only"))
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 500))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)

        let dragged = SidebarRowKey.workspace(WorkspaceID("only"))
        let row = try #require(list.displayed.row(for: dragged))
        let start = NSPoint(x: 80, y: row.y + row.height / 2)
        list.press = SidebarPress(key: dragged, point: start)
        list.beginDrag(try #require(list.press))
        try #require(list.drag != nil, "the member did not lift")
        // Past the last row as the drag draws the list; the emptied group keeps only its header.
        @MainActor func bottom() -> CGFloat { (list.displayed.rows.last?.maxY ?? 300) + 10 }
        var y = start.y, gone: [Int] = [], frame = 0
        while y < bottom(), frame < 200 {
            y += 6
            frame += 1
            list.updateDrag(windowPoint: list.convert(NSPoint(x: start.x, y: y), to: nil))
            if list.displayed.row(for: .group(solo)) == nil { gone.append(frame) }
        }
        #expect(gone.isEmpty, "the group's header left the list during the drag at frames \(gone)")
        guard case let .position(position)? = list.drag?.target, position.group == nil else {
            Issue.record("the drag did not end over a loose slot: \(String(describing: list.drag?.target))")
            return
        }
        list.finishDrag()
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(model.group(solo) == nil, "the emptied group is still in the model after the drop")
        #expect(list.displayed.row(for: .group(solo)) == nil, "the emptied group's header still shows after the drop")
    }
}

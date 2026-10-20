import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-19 (u2455): "I think the sidebar renders too often." The
/// sidebar's work counters (`SidebarPerfCounters`) per phase, with 10 and 100
/// workspaces (a third in groups): idle, a selection change, a click on a row, streaming output
/// (one row's text changing), typing (a row patch that changes nothing), and
/// a group drag (moves, then the drop). A change that is not structural
/// re-renders only the rows it changed: it never lays the list out again and
/// never configures every row. Each run prints its counts ("render-counts").
@MainActor @Suite(.serialized) struct SidebarRenderCountTests {
    struct Harness {
        let sidebar: SidebarView
        let model: SidebarModel
        let window: NSWindow
        let ids: [WorkspaceID]
        let groups: [GroupID]
        var list: SidebarListView { sidebar.list }
        /// The realized rows (what a full re-render configures).
        var realized: Int { list.rowViews.count }
    }

    static func make(_ count: Int) -> Harness {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (0..<count).map { WorkspaceID("rc-\($0)") }
        let ws = { (id: WorkspaceID) in SidebarWorkspace(id: id, title: id.rawValue) }
        // Three groups share the first third; the rest are loose.
        let grouped = count / 3, perGroup = max(1, grouped / 3)
        var nodes: [SidebarNode] = []
        var groups: [GroupID] = []
        for g in 0..<3 {
            let members = ids[min(ids.count, g * perGroup)..<min(ids.count, (g + 1) * perGroup)]
            guard !members.isEmpty else { continue }
            let id = GroupID("rc-g\(g)")
            groups.append(id)
            nodes.append(.group(SidebarGroup(id: id, name: "Group \(g)", color: .green, workspaces: members.map(ws))))
        }
        nodes += ids[min(ids.count, 3 * perGroup)...].map { .workspace(ws($0)) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids.first)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return Harness(sidebar: sidebar, model: model, window: window, ids: ids, groups: groups)
    }

    /// The counters since the last call.
    static func counts() -> (reloads: Int, configures: Int, patches: Int) {
        let r = SidebarPerfCounters.report(reset: true)
        return (r["list_reloads"] ?? 0, r["row_configures"] ?? 0, r["row_patches"] ?? 0)
    }

    /// Lets the observation stream and the row feed run (no state to wait for: idle means nothing should happen).
    static func settle() async {
        for _ in 0..<5 { await Task.yield() }
        // Idle is a span of time: half a second of it, as a user watching the sidebar sees.
        try? await Task.sleep(for: .milliseconds(500))
    }

    @Test(arguments: [10, 100])
    func renderCounts(_ count: Int) async throws {
        let h = Self.make(count)
        defer { h.window.close() }
        await Self.settle()
        _ = Self.counts()
        let realized = h.realized
        try #require(realized > 4, "rows realized: \(realized)")

        // Idle.
        await Self.settle()
        let idle = Self.counts()

        // A selection change (a click on another workspace, as the app answers it).
        let target = h.ids[3] // on screen: a reveal scroll would realize other rows
        h.model.click(target)
        h.model.activeWorkspaceID = target
        h.sidebar.renderNow()
        await Self.settle()
        let selection = Self.counts()

        // A real click (mouse down and up) on another workspace's row.
        let clicked = try #require(h.list.displayed.row(for: .workspace(h.ids[5])))
        let at = h.list.convert(NSPoint(x: 80, y: clicked.y + clicked.height / 2), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0,
                                                        windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            if type == .leftMouseDown { h.list.mouseDown(with: event) } else { h.list.mouseUp(with: event) }
        }
        h.sidebar.renderNow()
        await Self.settle()
        let click = Self.counts()

        // Streaming output: one row's title changes 20 times.
        let streamed = h.ids[1]
        for i in 0..<20 {
            var row = SidebarWorkspace(id: streamed, title: "output \(i)")
            row.status = "line \(i)"
            #expect(h.model.patchWorkspaces([row]))
        }
        await Self.settle()
        let streaming = Self.counts()

        // Typing: the terminal's row reports what it already shows (no change).
        for _ in 0..<20 { #expect(h.model.patchWorkspaces([SidebarWorkspace(id: h.ids[2], title: h.ids[2].rawValue)])) }
        await Self.settle()
        let typing = Self.counts()

        // A group drag: 20 moves, then the drop and its landing.
        let group = try #require(h.groups.first)
        let header = try #require(h.list.displayed.row(for: .group(group)))
        let start = NSPoint(x: 80, y: header.y + header.height / 2)
        h.list.press = SidebarPress(key: header.key, point: start)
        h.list.beginDrag(try #require(h.list.press))
        _ = Self.counts()
        let realizedAtDrop = h.realized
        for step in 1...20 { h.list.updateDrag(windowPoint: h.list.convert(NSPoint(x: start.x, y: start.y + CGFloat(step) * 3), to: nil)) }
        let moves = Self.counts()
        h.list.finishDrag()
        if let landing = h.list.landing { h.list.finishLand(landing, then: nil) }
        let drop = Self.counts()

        print("render-counts n=\(count) realized=\(realized) idle=\(idle) selection=\(selection) click=\(click) streaming=\(streaming) "
              + "typing=\(typing) dragMoves=\(moves) drop=\(drop) realizedAtDrop=\(realizedAtDrop)")

        #expect(idle.reloads == 0 && idle.configures == 0, "idle re-rendered: \(idle)")
        #expect(selection.reloads == 0, "a selection change laid the whole list out: \(selection)")
        #expect(selection.configures <= 2, "a selection change configured \(selection.configures) of \(realized) rows")
        #expect(click.reloads == 0, "a click on a row laid the whole list out: \(click)")
        #expect(click.configures <= 2, "a click configured \(click.configures) of \(realized) rows")
        #expect(streaming.reloads == 0, "streaming output laid the whole list out: \(streaming)")
        // Each patch configures its row (and a group member's header): never the other rows.
        #expect(streaming.configures <= 20 * 2, "20 patches of one row configured \(streaming.configures) rows")
        #expect(typing.reloads == 0 && typing.configures == 0 && typing.patches == 0, "an unchanged row re-rendered: \(typing)")
        #expect(moves.reloads == 0 && moves.configures <= 2, "drag moves re-rendered rows: \(moves)")
        // The drop moves rows (one layout); it configures each realized row at most once.
        #expect(drop.reloads <= 1 && drop.configures <= realizedAtDrop,
                "the drop re-rendered \(drop.configures) for \(realizedAtDrop) realized rows: \(drop)")
    }
}

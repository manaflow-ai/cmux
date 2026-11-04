import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// REOPEN-F7: a reopened window's first layout pass took 46-55 ms profiled at 100 workspaces (profile 11). At the first
/// frame's commit the bench counted 2684 `-[NSView layout]` calls in a window of 1574 views: the 403 hidden labels of
/// the 28 row views were laid out 780 times, their hidden icon buttons and image views twice each too, while each row
/// view itself was laid out once. Chrome's first paint lays out only what shows (a `display: none` box gets no layout),
/// once. The floor here: before the first frame, a view class in the sidebar gets at most one layout call per shown view.
///
/// Counted with `LayoutPassGuard` (`-[NSView layout]` calls per view class), so the result is the same on each run.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFirstFrameLayoutPassTests {
    private static let count = 100, active = 80, height: CGFloat = 640

    /// Layout calls per view class since launch (the guard counts per class).
    private static func calls() -> [String: Int] {
        Dictionary(LayoutPassGuard.shared.passesByClass.map { ($0.viewClass, $0.passes) }, uniquingKeysWith: +)
    }

    private static func delta(_ now: [String: Int], _ before: [String: Int]) -> [String: Int] {
        now.reduce(into: [:]) { result, entry in
            let added = entry.value - (before[entry.key] ?? 0)
            if added > 0 { result[entry.key] = added }
        }
    }

    /// Views under `root` per class: all of them and the shown ones (no hidden ancestor).
    private static func views(under root: NSView) -> [String: (all: Int, shown: Int)] {
        var result: [String: (all: Int, shown: Int)] = [:]
        func walk(_ view: NSView) {
            let name = String(describing: type(of: view))
            var entry = result[name] ?? (0, 0)
            entry.all += 1
            if !view.isHiddenOrHasHiddenAncestor { entry.shown += 1 }
            result[name] = entry
            view.subviews.forEach(walk)
        }
        walk(root)
        return result
    }

    /// A window's first frame, in the order WindowController makes it: the sidebar is made, the window lays it out,
    /// the first render runs, the window shows and displays. Returns the sidebar, its window, and the layout calls per
    /// view class from the sidebar's creation through the first display, with each step's calls for the message.
    private static func firstFrame() -> (SidebarView, NSWindow, calls: [String: Int], steps: [String]) {
        _ = NSApplication.shared
        LayoutPassGuard.shared.install()
        let start = calls()
        var steps: [String] = [], mark = start
        func step(_ name: String) {
            let now = calls()
            let added = delta(now, mark).sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }
            steps.append("\(name): \(added.joined(separator: ", "))")
            mark = now
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (0..<count).map { WorkspaceID("first-pass-\($0)") }
        let nodes = ids.enumerated().map { index, id in
            SidebarNode.workspace(SidebarWorkspace(id: id, title: "project-\(index)", directory: "~/p\(index)"))
        }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids[active])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        step("init")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        step("in window")
        sidebar.layoutSubtreeIfNeeded()
        step("first layout")
        sidebar.renderNow()
        step("render")
        sidebar.layoutSubtreeIfNeeded()
        step("second layout")
        window.orderFrontRegardless()
        window.displayIfNeeded()
        step("display")
        return (sidebar, window, delta(calls(), start), steps)
    }

    @Test func noViewClassIsLaidOutMoreThanItsShownViewsBeforeTheFirstFrame() throws {
        let (sidebar, window, calls, steps) = Self.firstFrame()
        defer { window.close() }
        let rows = sidebar.list.rowViews.values.filter { $0 is WorkspaceRowView && !$0.isHidden }.count
        try #require(rows > 0, "the first frame has no workspace row view")
        let views = Self.views(under: sidebar)
        let over = calls.compactMap { name, made -> String? in
            guard let shown = views[name]?.shown, let all = views[name]?.all, made > shown else { return nil }
            return "\(name) \(made) calls for \(shown) shown of \(all)"
        }.sorted()
        #expect(over.isEmpty, "laid out beyond the shown views before the first frame: \(over.joined(separator: "; ")). Steps: \(steps.joined(separator: " | "))")
    }
}

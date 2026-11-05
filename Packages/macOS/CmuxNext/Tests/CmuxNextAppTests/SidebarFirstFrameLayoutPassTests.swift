import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// REOPEN-F7: a reopened window's first layout pass took 46-55 ms profiled at 100 workspaces (profile 11). At the first
/// frame's commit the bench counted 2684 `-[NSView layout]` calls in a window of 1574 views: each of the 28 row views was
/// laid out once, but their hidden controls and labels 1 to 2 times each (SidebarIconButton 246 calls for 123 views,
/// 121 of them hidden). Chrome's first paint gives a `display: none` box no layout box. A row's hover and content
/// controls (close, menu button, Unpin, tree fold, audio) are made the first time they show (`RowControlSlot`), so the
/// first frame neither makes nor lays them out; the first hover shows them in its own frame.
///
/// Counted with `LayoutPassGuard` (`-[NSView layout]` calls per view class), so the result is the same on each run.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFirstFrameLayoutPassTests {
    private static let count = 100, active = 80, height: CGFloat = 640

    /// Layout calls per view class since launch (the guard counts per class).
    private static func calls() -> [String: Int] {
        Dictionary(LayoutPassGuard.shared.passesByClass.map { ($0.viewClass, $0.passes) }, uniquingKeysWith: +)
    }

    /// The row controls this step makes lazily.
    private static func isRowControl(_ view: NSView) -> Bool { view is SidebarIconButton || view is OverflowButton }

    /// Every view under `root`, root first.
    private static func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    /// A window's first frame, in the order WindowController makes it: the sidebar is made, the window lays it out,
    /// the first render runs, the window shows and displays. Returns the sidebar, its window and the layout calls per
    /// view class from the sidebar's creation through the first display.
    private static func firstFrame() -> (SidebarView, NSWindow, calls: [String: Int]) {
        _ = NSApplication.shared
        LayoutPassGuard.shared.install()
        let start = calls()
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (0..<count).map { WorkspaceID("first-pass-\($0)") }
        let nodes = ids.enumerated().map { index, id in
            SidebarNode.workspace(SidebarWorkspace(id: id, title: "project-\(index)", directory: "~/p\(index)"))
        }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids[active])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let now = calls()
        return (sidebar, window, now.reduce(into: [:]) { result, entry in
            let added = entry.value - (start[entry.key] ?? 0)
            if added > 0 { result[entry.key] = added }
        })
    }

    private static func workspaceRows(_ sidebar: SidebarView) -> [WorkspaceRowView] {
        sidebar.list.rowViews.values.compactMap { $0 as? WorkspaceRowView }.filter { !$0.isHidden }
    }

    @Test func aRestingRowMakesNoHoverControls() throws {
        let (sidebar, window, _) = Self.firstFrame()
        defer { window.close() }
        let rows = Self.workspaceRows(sidebar)
        try #require(!rows.isEmpty, "the first frame has no workspace row view")
        // The seed's workspaces play no sound and start no subtree: at rest a row shows none of the five.
        let made = rows.map { $0.subviews.filter(Self.isRowControl).count }.reduce(0, +)
        #expect(made == 0, "\(rows.count) resting rows made \(made) hover or content controls before the first frame")
    }

    @Test func theFirstFrameLaysOutOnlyTheIconButtonsItShows() throws {
        let (sidebar, window, calls) = Self.firstFrame()
        defer { window.close() }
        let rows = Self.workspaceRows(sidebar)
        try #require(!rows.isEmpty, "the first frame has no workspace row view")
        let inRows = Set(rows.flatMap { Self.descendants(of: $0) }.map(ObjectIdentifier.init))
        let controls = Self.descendants(of: sidebar).filter(Self.isRowControl)
        // The sidebar's own buttons (titlebar, footer, cards) are not this cut's; a row's count only when shown.
        let floor = controls.filter { !inRows.contains(ObjectIdentifier($0)) || !$0.isHiddenOrHasHiddenAncestor }.count
        let made = (calls[String(describing: SidebarIconButton.self)] ?? 0) + (calls[String(describing: OverflowButton.self)] ?? 0)
        #expect(made <= floor, "the first frame laid out icon and menu buttons \(made) times; \(floor) are outside the rows or shown")
    }

    /// The lead's condition: a control made on its first show costs no frame. The hover that shows it makes it in the
    /// same turn, so the frame that hover draws already has it, shown, placed and with its icon.
    @Test func theFirstHoverShowsItsControlsInThatFrame() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (sidebar, window, _) = Self.firstFrame()
        defer { window.close() }
        let key = SidebarRowKey.workspace(WorkspaceID("first-pass-\(Self.active)"))
        let row = try #require(sidebar.list.rowViews[key] as? WorkspaceRowView, "the active row has no view")
        row.onMore = {} // the App's menu provider wires it (`WorkspaceRowView+Wiring`); this sidebar has none
        sidebar.list.setHovered(key)
        window.displayIfNeeded() // the hover's frame: no run loop turn between the hover and it
        let shown = row.subviews.filter { Self.isRowControl($0) && !$0.isHidden && $0.alphaValue > 0.99 }
        let close = try #require(shown.compactMap { $0 as? SidebarIconButton }.first { $0.accessibilityLabel() == Strings.closeButton },
                                 "the first hover's frame shows no close")
        let more = try #require(shown.first { $0 is OverflowButton }, "the first hover's frame shows no menu button")
        for (name, control) in [("close", close as NSView), ("menu", more)] {
            #expect(!control.frame.isEmpty && row.bounds.contains(control.frame), "the \(name) button sits at \(control.frame) in \(row.bounds)")
        }
        let icon = try #require(close.image, "the close shows without its icon")
        #expect(icon.size.width > 1, "the close shows AppKit's placeholder image, not its icon")
        #expect(close.frame.minX > more.frame.minX, "the close is not right of the menu button")
    }
}

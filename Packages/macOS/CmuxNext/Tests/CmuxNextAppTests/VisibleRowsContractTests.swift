import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextNotifications
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxVisibleRows
import CmuxVisibleRowsTesting
import Foundation
import QuartzCore
import Testing

/// Leo 2026-11-18 (ask-1105ee4cc6): "we draw the visible area, right? Like, that's what we're supposed to do." The
/// lists registered with the visible-rows contract (`VisibleRowsContract`), each at 100 and 10,000 rows. A list that
/// does not meet the contract yet is named in `VisibleRowsBaseline`; its fix deletes that line.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct VisibleRowsContractTests {
    @Test func sidebarWorkspaces() async throws {
        try await VisibleRowsContract.check(SidebarWorkspaceRows.self)
    }

    /// In `VisibleRowsBaseline` (CmuxVisibleRows): the panel makes a new row view for every ledger entry on every render.
    @Test func notificationsPanel() async throws {
        try await VisibleRowsContract.check(NotificationsPanelRows.self)
    }
}

/// Lets the sidebar's observation stream and row feed run.
@MainActor private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(300))
}

/// Lays the window out, draws it and commits, as a display frame does.
@MainActor private func drawFrame(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.flush()
}

/// The sidebar's workspace list: `rows` loose workspaces in a 260 x 900 window.
@MainActor final class SidebarWorkspaceRows: VisibleRowsFixture {
    static let name = "sidebar workspaces"
    let sidebar: SidebarView
    let model: SidebarModel
    let window: NSWindow
    let ids: [WorkspaceID]
    var list: SidebarListView { sidebar.list }
    var clip: NSClipView { sidebar.scrollView.contentView }

    init(rows: Int) async throws {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        ids = (0..<rows).map { WorkspaceID("vr-\($0)") }
        let nodes = ids.enumerated().map { index, id in
            var ws = SidebarWorkspace(id: id, title: id.rawValue, directory: "~/fun/feature-\(index)", branch: "feat-\(index)")
            ws.status = "step \(index)"
            return SidebarNode.workspace(ws)
        }
        model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids.first)
        sidebar = SidebarView(model: model, design: DesignSettings())
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 900), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        window.orderFrontRegardless()
        sidebar.renderNow()
        drawFrame(window)
        await settle()
    }

    var viewportRows: Int {
        let visible = clip.bounds
        return list.displayed.rows.filter { visible.intersects(list.frame(for: $0)) }.count
    }

    /// A shown workspace's status line changes (an agent's output), as the app patches it.
    func changeOneItem() async throws {
        var row = SidebarWorkspace(id: ids[2], title: ids[2].rawValue, directory: "~/fun/feature-2", branch: "feat-2")
        row.status = "changed"
        try #require(model.patchWorkspaces([row]), "the model refused the patch")
        await settle()
        drawFrame(window)
    }

    /// From the middle of the list (that move is not measured), one row down.
    func scrollOneRow() async throws -> Bool {
        let maxY = max(0, list.frame.height - clip.bounds.height)
        guard maxY > 0, let first = list.displayed.rows.first else { return false }
        scroll(to: min(maxY / 2, 2_000))
        _ = list.listWork.take()
        scroll(to: clip.bounds.minY + first.height)
        return true
    }

    private func scroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        sidebar.scrollView.reflectScrolledClipView(clip)
        drawFrame(window)
    }

    /// One live-resize step of the window: 8 pt narrower.
    func resizeOneStep() async throws -> Bool {
        window.setContentSize(NSSize(width: 252, height: 900))
        drawFrame(window)
        await settle()
        drawFrame(window)
        return true
    }

    func close() { window.close() }
}

/// The notifications panel over `rows` ledger entries, a row view made for each as `NotificationsPanelController.render` does.
@MainActor final class NotificationsPanelRows: VisibleRowsFixture {
    static let name = "notifications panel"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    let card = NotificationsPanelView()
    let window: NSWindow
    var rows: [NotificationsPanelRow]
    var list: NotificationsPanelView { card }

    init(rows count: Int) async throws {
        _ = NSApplication.shared
        rows = (0..<count).map { Self.row($0, unread: $0 % 3 == 0) }
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: NotificationsPanelView.width, height: 600), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = card
        window.orderFrontRegardless()
        render()
    }

    static func row(_ index: Int, unread: Bool) -> NotificationsPanelRow {
        NotificationsPanelRow(id: "vr-\(index)", title: "Build \(index) finished", subtitle: nil, body: "All checks passed on step \(index)",
                              level: .info, source: "agent", workspaceTitle: "cmux",
                              createdAt: now.addingTimeInterval(-60 * Double(index)), unread: unread, surface: nil, terminal: nil)
    }

    /// What the controller's render does: new row views, shown, the selection drawn, the panel sized to the card.
    func render() {
        let views = rows.map { NotificationRowView(row: $0, now: Self.now, callbacks: .init(open: {}, dismiss: {}, menu: { NSMenu() })) }
        _ = card.show(views, loaded: true)
        card.select(nil)
        window.setContentSize(card.fittingSize)
        drawFrame(window)
    }

    var viewportRows: Int { card.rowViews.filter { !$0.visibleRect.isEmpty }.count }

    /// A notification is read: the ledger's reply marks one row read (the panel reloads on an unread change).
    func changeOneItem() async throws {
        let read = rows[1]
        rows[1] = Self.row(1, unread: !read.unread)
        render()
    }

    func scrollOneRow() async throws -> Bool {
        guard let scroll = Self.scrollView(in: card), let first = card.rowViews.first else { return false }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + first.frame.height))
        scroll.reflectScrolledClipView(clip)
        drawFrame(window)
        return true
    }

    /// The panel is a fixed width (`NotificationsPanelView.width`).
    func resizeOneStep() async throws -> Bool { false }

    func close() { window.close() }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
}

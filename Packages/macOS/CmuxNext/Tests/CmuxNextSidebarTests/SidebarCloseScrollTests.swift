import AppKit
import Testing
@testable import CmuxNextSidebar

/// Sidebar scroll after a close, create or selection change
/// (plans/cmux-next/close-focus.md, bugs S1-S3 reproduced live on
/// ef59984a2f1): the active workspace is revealed when it changes, a row
/// removed above the viewport does not shift what the user sees, and an
/// active row that was fully visible does not move.
@MainActor @Suite struct SidebarCloseScrollTests {
    static let count = 40

    func makeSidebar(active: String = "w0") -> SidebarView {
        let nodes = (0..<Self.count).map { SidebarNode.workspace(w("w\($0)")) }
        let sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)), nodes: nodes)]
        let view = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id(active)))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        return view
    }

    func clip(_ view: SidebarView) throws -> NSClipView { try #require(view.list.enclosingScrollView?.contentView) }

    func scroll(_ view: SidebarView, to y: CGFloat) throws {
        let clip = try clip(view)
        clip.scroll(to: NSPoint(x: 0, y: y))
        view.list.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// On-screen y of a workspace row (content y minus the scroll offset).
    func screenY(_ view: SidebarView, _ name: String) throws -> CGFloat {
        let row = try #require(view.list.displayed.row(for: .workspace(id(name))))
        return row.y - (try clip(view).bounds.minY)
    }

    func remove(_ view: SidebarView, _ name: String) {
        var sections = view.model.sections
        sections[0].nodes.removeAll { if case let .workspace(ws) = $0 { ws.id == id(name) } else { false } }
        view.model.sections = sections
    }

    func fullyVisible(_ view: SidebarView, _ name: String) throws -> Bool {
        let row = try #require(view.list.displayed.row(for: .workspace(id(name))))
        let visible = try clip(view).bounds
        return row.y >= visible.minY - 0.5 && row.y + row.height <= visible.maxY + 0.5
    }

    // S2: a CLI close of a row above the viewport shifted every row up.
    @Test func closingARowAboveTheViewportKeepsWhatTheUserSees() throws {
        let view = makeSidebar(active: "w20")
        let rowHeight = try #require(view.list.displayed.row(for: .workspace(id("w1")))).height
        try scroll(view, to: rowHeight * 6)
        let before = try screenY(view, "w12")
        remove(view, "w2")
        view.list.reload(animated: false)
        #expect(abs(try screenY(view, "w12") - before) < 0.5)
    }

    // S1: a new (or newly selected) workspace far below was not revealed.
    @Test func anActiveWorkspaceOutOfViewIsRevealedWhenItBecomesActive() throws {
        let view = makeSidebar(active: "w0")
        view.model.activeWorkspaceID = id("w39")
        view.list.reload(animated: false)
        #expect(try fullyVisible(view, "w39"))
    }

    // S3: closing the selected workspace selected a neighbor left cut off.
    @Test func theSuccessorOfAClosedActiveWorkspaceIsFullyVisible() throws {
        let view = makeSidebar(active: "w39")
        view.model.activeWorkspaceID = id("w39")
        let rowHeight = try #require(view.list.displayed.row(for: .workspace(id("w1")))).height
        try scroll(view, to: rowHeight * 10)
        remove(view, "w39")
        view.model.activeWorkspaceID = id("w38")
        view.list.reload(animated: false)
        #expect(try fullyVisible(view, "w38"))
    }

    // V3: no jump when the active row stays visible.
    @Test func closingARowBelowDoesNotMoveAVisibleActiveRow() throws {
        let view = makeSidebar(active: "w8")
        let rowHeight = try #require(view.list.displayed.row(for: .workspace(id("w1")))).height
        try scroll(view, to: rowHeight * 4)
        let before = try screenY(view, "w8")
        remove(view, "w30")
        view.list.reload(animated: false)
        #expect(abs(try screenY(view, "w8") - before) < 0.5)
    }
}

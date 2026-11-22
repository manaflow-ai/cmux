import AppKit
import Testing
@testable import CmuxNextSidebar

/// Dogfood nxdog13: "make sure workspace list can't scroll if there aren't
/// enough workspaces to scroll down to." The list neither scrolls nor
/// rubber-bands while every row fits, and bounces again once rows overflow.
@MainActor @Suite struct SidebarScrollFitTests {
    func sidebar(extra: Int, height: CGFloat) -> SidebarView {
        var sections = fixture()
        sections[1].nodes.append(contentsOf: (0..<extra).map { SidebarNode.workspace(w("extra\($0)")) })
        let view = SidebarView(model: SidebarModel(sections: sections, activeWorkspaceID: id("a")))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        return view
    }

    @Test func aListThatFitsDoesNotBounce() throws {
        let view = sidebar(extra: 0, height: 900)
        let scroll = try #require(view.list.enclosingScrollView)
        #expect(view.list.displayed.totalHeight < scroll.contentView.bounds.height)
        #expect(scroll.verticalScrollElasticity == .none)
    }

    @Test func aListThatOverflowsBounces() throws {
        let view = sidebar(extra: 60, height: 400)
        let scroll = try #require(view.list.enclosingScrollView)
        #expect(scroll.verticalScrollElasticity == .allowed)
    }

    @Test func elasticityFollowsWorkspacesAddedAndTheWindowResized() throws {
        let view = sidebar(extra: 0, height: 900)
        let scroll = try #require(view.list.enclosingScrollView)
        #expect(scroll.verticalScrollElasticity == .none)
        view.setFrameSize(NSSize(width: 260, height: 120))
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        #expect(scroll.verticalScrollElasticity == .allowed)
        view.setFrameSize(NSSize(width: 260, height: 900))
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        #expect(scroll.verticalScrollElasticity == .none)
    }

    /// Lawrence (2026-10-05, nxdog56): "No workspaces" over a tall, always-shown scroll bar. The
    /// document was at least as tall as the clip when rows were laid out, and a clip that shrank
    /// later (the bands or the window) kept that height, so an empty or short list scrolled. The
    /// document follows the clip without a reload: rows that fit never scroll.
    @Test(arguments: [true, false])
    func aListThatFitsStopsScrollingWhenTheClipShrinks(empty: Bool) throws {
        let view = empty ? SidebarView(model: SidebarModel()) : sidebar(extra: 0, height: 900)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        view.setFrameSize(NSSize(width: 260, height: 780))
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.list.enclosingScrollView)
        let clip = scroll.contentView.bounds.height
        #expect(view.list.displayed.totalHeight <= clip, "the rows fit")
        #expect(view.list.frame.height <= clip + 0.5, "document \(view.list.frame.height) in a clip \(clip): nothing to scroll")
        #expect(scroll.verticalScrollElasticity == .none)
    }
}

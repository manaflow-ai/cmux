import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The sidebar scrolls with the chat's thin scroller (Leo 2026-10-21, on a fat sidebar scrollbar
/// with a track): the list, the pinned bands and the Priority view take the shared
/// ``ThinScroller``, a 3 pt overlay knob on no track that fades at rest and widens near the
/// pointer, and keep it after the macOS "Show scroll bars" setting changes.
@MainActor
@Suite(.serialized)
struct SidebarThinScrollerTests {
    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspaces = (0..<60).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace \($0)")) }
        let sidebar = SidebarView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces)]),
                                  design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private static func sidebarScrollViews(_ sidebar: SidebarView) -> [NSScrollView] {
        [sidebar.scrollView, sidebar.aboveScroll, sidebar.belowScroll]
            + scrollViews(in: sidebar.priorityPanelView).filter(\.hasVerticalScroller)
    }

    @Test func everySidebarScrollViewTakesTheSharedThinScroller() {
        defer { SystemScrollers.preferredStyleOverride = nil }
        let sidebar = Self.sidebar()
        let views = Self.sidebarScrollViews(sidebar)
        #expect(views.count >= 4) // the list, both bands and the Priority view
        for view in views {
            #expect(view.verticalScroller is ThinScroller)
            #expect(view.scrollerStyle == .overlay)
            #expect(view.autohidesScrollers)
        }
        #expect(ThinScroller.knobThickness == 3)
        SystemScrollers.preferredStyleOverride = .legacy
        SystemScrollers.systemStyleDidChange()
        for view in views {
            #expect(view.scrollerStyle == .overlay)
            #expect(view.verticalScroller is ThinScroller)
        }
    }

    @Test func theListScrollerFollowsTheAutoHideSwitch() throws {
        defer { SystemScrollers.thinScrollersAutoHide = true }
        let sidebar = Self.sidebar()
        let scroller = try #require(sidebar.scrollView.verticalScroller as? ThinScroller)
        // Hidden at rest, shown while scrolling or with the pointer near (Lawrence 2026-10-23).
        #expect(scroller.autoHides)
        #expect(scroller.restingKnobFrame == nil)
        SystemScrollers.thinScrollersAutoHide = false
        #expect(!scroller.autoHides) // the opt-out: shown while the list overflows
    }
}

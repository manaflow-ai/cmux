import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The workspace hover card's history scrolls with the shared thin scroller (2026-10-20: one
/// super-thin scrollbar style for every scrollable card).
@MainActor
@Suite struct HoverCardThinScrollerTests {
    @Test func theHistoryScrollsWithTheThinScroller() {
        let timeline = WorkspaceHoverCardTimelineView()
        #expect(timeline.scrollView.verticalScroller is ThinScroller)
        #expect(timeline.scrollView.scrollerStyle == .overlay)
    }
}

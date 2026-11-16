import AppKit
import CmuxNextDesign
import CmuxNextHome
import Testing

/// The Home sidebar's conversation list (MessagesLab's vendored list) has the thin overlay
/// scroller every other cmux scroller has (SCROLLBARS-THIN, Leo 2026-10-12: "never a permanent
/// gray track"), also after the macOS "Show scroll bars" setting changes to "Always".
@MainActor
struct HomeSidebarScrollerTests {
    @Test func theHomeSidebarListScrollerStaysOverlayAfterTheSettingChanges() throws {
        let sidebar = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        let list = try #require(Self.scrollViews(in: sidebar).first { $0.hasVerticalScroller })
        list.scrollerStyle = .legacy // what AppKit does when the setting changes
        SystemScrollers.systemStyleDidChange()
        #expect(list.scrollerStyle == .overlay)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
}

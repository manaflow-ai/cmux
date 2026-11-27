import AppKit
@testable import CmuxNextDesign
import Testing

/// Native scrollers are overlay ones whatever the macOS "Show scroll bars" setting (Leo
/// 2026-10-12: "never a permanent gray track"): thin, hidden at rest, shown while scrolling. With
/// "Always" a followed scroll view stays overlay, also after the setting changes, and pages still
/// learn the setting (WebKit draws its own bars, which the shared web rules then thin).
@MainActor
@Suite(.serialized)
struct ThinScrollersTests {
    @Test func scrollViewsStayOverlayWhenTheSystemSaysAlways() {
        defer { SystemScrollers.preferredStyleOverride = nil }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        SystemScrollers.preferredStyleOverride = .legacy
        SystemScrollers.follow(scrollView)
        let followed = scrollView.scrollerStyle
        SystemScrollers.preferredStyleOverride = .overlay
        SystemScrollers.systemStyleDidChange()
        SystemScrollers.preferredStyleOverride = .legacy
        SystemScrollers.systemStyleDidChange()
        #expect(followed == .overlay)
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(SystemScrollers.pageValue == "legacy")
    }

    /// A page's `<select>` popup scrolls when its rows don't fit the screen, and its scroller is
    /// thin too, also after the setting changes (AppKit resets a scroll view's style then).
    @Test func aPagePopupScrollerStaysOverlayAfterTheSettingChanges() throws {
        let panel = WebPopupPanel(onPick: { _ in }, onHover: { _ in })
        let scrollView = try #require(Self.scrollViews(in: panel.contentView).first)
        scrollView.scrollerStyle = .legacy // what AppKit does when the setting changes
        SystemScrollers.systemStyleDidChange()
        #expect(scrollView.scrollerStyle == .overlay)
    }

    static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
}

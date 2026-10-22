import AppKit
@testable import CmuxNextDesign
import Testing

/// SCROLLBARS-VISIBLE (supersedes SCROLLBARS-THIN; webviews/src/scrollers.ts). Leo 2026-10-21:
/// "WHY DOES THE SCROLLBAR IN THE CHAT AREA KEEP HIDING ITSELF ... THERE IS NO AGENT APP THAT DOES
/// THIS". A scroller is thin, has no track ("never a permanent gray track", 2026-10-12) and is
/// visible at rest while its content overflows; hiding at rest is never the default. Natively a
/// followed scroll view stays an overlay scroller whatever the macOS "Show scroll bars" setting, so
/// it never takes width from the content or draws a track (a resting knob is drawn over it), and
/// pages learn the setting: with "Always" the shared web rules draw their thin bar at rest. The
/// retired SCROLLBARS-THIN version of this suite said "hidden at rest, shown while scrolling";
/// never restore that to pass it.
@MainActor
@Suite(.serialized)
struct ThinScrollersTests {
    @Test func scrollViewsStayTracklessWhenTheSystemSaysAlways() {
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
    }

    /// "Always" reaches pages, whose shared rules then show the thin bar at rest (scrollers.ts
    /// `SCROLLER_ROOT_CSS`, thin-scrollers.test.ts); a page is never told to hide it.
    @Test func pagesLearnAlwaysSoTheirBarsShowAtRest() {
        defer { SystemScrollers.preferredStyleOverride = nil }
        SystemScrollers.preferredStyleOverride = .legacy
        #expect(SystemScrollers.pageValue == "legacy")
        SystemScrollers.preferredStyleOverride = .overlay
        #expect(SystemScrollers.pageValue == "overlay")
    }

    /// A page's `<select>` popup scrolls when its rows don't fit the screen, and its scroller stays
    /// trackless too, also after the setting changes (AppKit resets a scroll view's style then).
    @Test func aPagePopupScrollerStaysTracklessAfterTheSettingChanges() throws {
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

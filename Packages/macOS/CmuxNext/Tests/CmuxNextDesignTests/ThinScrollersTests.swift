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
}

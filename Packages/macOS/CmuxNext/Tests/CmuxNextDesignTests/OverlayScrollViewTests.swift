import AppKit
@testable import CmuxNextDesign
import Testing

/// Leo 2026-11-15: "there's some crazy sort of layout shift on teh sidebar when i move my mouse over to
/// another display/desktop maybe? like the shared keyboard/mouse thing". Universal Control's shared
/// mouse leaving and returning flips `NSScroller.preferredScrollerStyle`, and AppKit resets every
/// scroll view to it. A legacy style reserves the scroller's width in the clip, so the content
/// narrowed and widened back on each flip. An ``OverlayScrollView`` takes no other style, so its
/// clip, and everything laid out to it, keeps one width.
@MainActor
@Suite(.serialized)
struct OverlayScrollViewTests {
    private static let frame = NSRect(x: 0, y: 0, width: 240, height: 200)

    /// A scroll view whose document overflows, so a legacy scroller would show and take width.
    private static func overflowing<V: NSScrollView>(_ scrollView: V, thin: Bool) -> V {
        scrollView.hasVerticalScroller = true
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height * 4))
        if thin { SystemScrollers.followThin(scrollView) } else { SystemScrollers.follow(scrollView) }
        scrollView.tile()
        return scrollView
    }

    @Test(arguments: [false, true])
    func appKitsResetToLegacyKeepsTheClipWidth(thin: Bool) {
        let scrollView = Self.overflowing(OverlayScrollView(frame: Self.frame), thin: thin)
        let before = scrollView.contentView.frame.width
        // What AppKit does to every scroll view when the system's style turns legacy.
        scrollView.scrollerStyle = .legacy
        scrollView.tile()
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.contentView.frame.width == before, "the clip changed width on a style flip")
        #expect(before == Self.frame.width, "an overlay scroller takes no width")
    }

    /// The control: a plain NSScrollView does lose the width, so the test above measures something.
    @Test func aPlainScrollViewLosesWidthToALegacyScroller() {
        let scrollView = Self.overflowing(NSScrollView(frame: Self.frame), thin: false)
        scrollView.scrollerStyle = .legacy
        scrollView.tile()
        #expect(scrollView.contentView.frame.width < Self.frame.width)
    }
}

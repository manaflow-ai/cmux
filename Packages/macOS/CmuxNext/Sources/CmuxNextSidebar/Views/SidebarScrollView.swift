import AppKit
import CmuxNextInput

/// The sidebar list's scroll view. A two-finger horizontal trackpad swipe
/// over it switches profiles instead of scrolling; vertical scrolling
/// is unchanged. One switch per gesture (`ProfileSwipeTracker`). A sideways
/// mouse wheel (tilt, or Shift) pages the spaces too, one per roll
/// (`SpaceWheelPager`); up or down always scrolls the list. Both hear the
/// app's input tap (`SidebarSwipeFeed`), not `scrollWheel(with:)`.
final class SidebarScrollView: NSScrollView {
    /// Called with -1 (previous) or +1 (next) once per qualifying swipe.
    var onHorizontalSwipe: ((Int) -> Void)? {
        get { swipes.onHorizontalSwipe }
        set { swipes.onHorizontalSwipe = newValue }
    }
    /// A horizontal gesture 1:1 (R99): its phase, finger dx and time. When
    /// set, it replaces the one-step swipe.
    var onHorizontalScroll: ((ProfileSwipeTracker.Phase, CGFloat, TimeInterval) -> Void)? {
        get { swipes.onHorizontalScroll }
        set { swipes.onHorizontalScroll = newValue }
    }
    /// A mouse wheel notch paged the spaces: -1 (previous) or +1 (next).
    var onWheelPage: ((Int) -> Void)? {
        get { swipes.onWheelPage }
        set { swipes.onWheelPage = newValue }
    }
    /// The app's one input tap (the sidebar passes the App's on): the paging hears this window's scrolls there.
    var inputTap: InputEventTap? {
        didSet { if inputTap !== oldValue { swipes.follow(tap: inputTap, window: window) } }
    }
    private(set) lazy var swipes = SidebarSwipeFeed(view: self, pagesVertically: false)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        swipes.follow(tap: inputTap, window: window)
    }

    /// Scrolls the list unless the paging took the event (a horizontal gesture, or a sideways wheel roll).
    override func scrollWheel(with event: NSEvent) {
        if swipes.takes(event) { return }
        super.scrollWheel(with: event)
    }
}

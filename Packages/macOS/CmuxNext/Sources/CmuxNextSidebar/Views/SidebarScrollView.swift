import AppKit

/// The sidebar list's scroll view. A two-finger horizontal trackpad swipe
/// over it switches profiles instead of scrolling; vertical scrolling
/// is unchanged. One switch per gesture (`ProfileSwipeTracker`). A sideways
/// mouse wheel (tilt, or Shift) pages the spaces too, one per roll
/// (`SpaceWheelPager`); up or down always scrolls the list. The input tap
/// feeds both before dispatch (`SidebarSwipeInput`).
final class SidebarScrollView: NSScrollView {
    /// Called with -1 (previous) or +1 (next) once per qualifying swipe.
    var onHorizontalSwipe: ((Int) -> Void)? {
        get { swipe.onHorizontalSwipe }
        set { swipe.onHorizontalSwipe = newValue }
    }
    /// A horizontal gesture 1:1 (R99): its phase, finger dx and time. When
    /// set, it replaces the one-step swipe.
    var onHorizontalScroll: ((ProfileSwipeTracker.Phase, CGFloat, TimeInterval) -> Void)? {
        get { swipe.onHorizontalScroll }
        set { swipe.onHorizontalScroll = newValue }
    }
    /// A mouse wheel notch paged the spaces: -1 (previous) or +1 (next).
    var onWheelPage: ((Int) -> Void)? {
        get { swipe.onWheelPage }
        set { swipe.onWheelPage = newValue }
    }
    /// The app's input tap; it feeds the swipe and the wheel paging for this window.
    var scrollTap: (any SidebarScrollTap)? {
        didSet { swipe.subscribe(scrollTap, view: self) }
    }
    private let swipe = SidebarSwipeInput(pagesVertically: false)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        swipe.subscribe(scrollTap, view: self)
    }

    override func scrollWheel(with event: NSEvent) {
        if !swipe.skipsScrolling(event) { super.scrollWheel(with: event) }
    }
}

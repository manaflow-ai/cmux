public import AppKit

/// A clip view that tells its scroll view's owner when it scrolls or changes size, from its own
/// setters, so the owner needs no `NSView.boundsDidChangeNotification` or
/// `frameDidChangeNotification` observer (and no `posts…ChangedNotifications` flag).
///
/// Chromium's `views::ScrollView` works this way: whoever owns the contents subscribes with
/// `AddContentsScrolledCallback`, and the scroll view runs those callbacks from `OnScrolled`
/// (`ui/views/controls/scroll_view.cc`); nothing goes through a process-wide notification.
///
/// ```swift
/// let clip = ScrollClipView()
/// clip.onScroll = { [weak self] in self?.realizeVisibleRows() }
/// scrollView.contentView = clip // before `documentView`
/// ```
///
/// Both callbacks run inline, in the setter's turn, so a scroll is handled in the order it happens.
@MainActor
public final class ScrollClipView: NSClipView {
    /// The bounds origin moved: a wheel or trackpad scroll, a scroller drag, `scroll(to:)`,
    /// or a step of an animated `setBoundsOrigin`.
    public var onScroll: (() -> Void)?
    /// The frame size changed (the scroll view tiled the clip to a new visible size).
    public var onResize: (() -> Void)?

    override public func setBoundsOrigin(_ newOrigin: NSPoint) {
        let old = bounds.origin
        super.setBoundsOrigin(newOrigin)
        if bounds.origin != old { onScroll?() }
    }

    override public func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        if frame.size != old { onResize?() }
    }
}

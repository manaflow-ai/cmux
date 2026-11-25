#if os(iOS)
import UIKit

/// T-SCROLL-12: in a full-screen app (the alternate screen) a vertical drag
/// scrolls the app, like a Mac trackpad in Ghostty, and the page stays
/// pinned. The drag is an ordinary UIScrollView scroll (Leo, 2026-11-25:
/// "for scrolling on iphone ... we can just treat the scroll like any
/// pedestrian scroll"): a hidden ``TerminalTUIScrollDriver`` owns the pan,
/// UIKit tracks the finger and decelerates the fling as in any list, and
/// each change of its offset becomes one wheel event on the surface
/// (`TerminalTUIScroll.Wheel`), the fling's as momentum. Ghostty turns them
/// into what the app asked for. Before, the alternate screen had no scroll
/// view: a bare pan recognizer scaled the finger by a speed gain and a
/// display link ran a fling of its own (0.95 per frame), so the app's
/// scroll neither moved nor slowed like the rest of iOS.
///
/// A tap still focuses the terminal, a long press still selects and a
/// selection handle still moves: the pan starts only on a vertical drag
/// that no selection gesture owns. A new touch stops a fling, as in any
/// scroll view, and a tap that stops one does nothing else (it does not
/// focus the terminal). The wheel stays at the cell where the drag began,
/// like the pointer during a trackpad scroll.
@MainActor
final class TerminalTUIScrollController: NSObject, @MainActor UIGestureRecognizerDelegate, @MainActor UIScrollViewDelegate {
    /// The app is on the alternate screen and the surface is in the TUI host.
    var isEnabled: () -> Bool = { false }
    /// A selection gesture owns the touch (a long press, a handle).
    var selectionOwns: (UITouch?) -> Bool = { _ in false }
    /// A drag began scrolling the app (its content moves under any selection).
    var dragBegan: () -> Void = {}
    /// The drag ended with no fling, was cancelled, or its fling ended or stopped.
    var panEnded: () -> Void = {}
    /// DEBUG: a wheel report went to the surface (cmux#48951's round trip).
    var wheelSent: () -> Void = {}
    /// A drag toward older rows asks to open the phone's reader of the app's
    /// history (``TerminalTUIReader``); true when it opened. That drag then
    /// moves the reader, not the app.
    var readerOpens: () -> Bool = { false }
    /// The reader's drag moved (its translation since it began).
    var readerMoved: (CGFloat) -> Void = { _ in }
    /// The reader's drag ended at this finger velocity (points per second).
    var readerEnded: (CGFloat) -> Void = { _ in }
    /// A wheel's `dy` (points): the part that still goes to the app after
    /// the session painted what it holds (``TerminalSession/panHeldRows(_:)``).
    var panHeld: (CGFloat) -> CGFloat = { $0 }

    private weak var surface: TerminalSurfaceView?
    /// The scroll view whose pan, moved to the host, is the drag.
    let driver = TerminalTUIScrollDriver()
    var pan: UIPanGestureRecognizer { driver.panGestureRecognizer }
    /// The driver's offsets as wheels.
    private var scroll = TerminalTUIScroll()
    /// A drag or its fling is under way (``panEnded`` goes out once).
    private var scrolling = false
    /// Moving the offset back to the middle is no scroll.
    private var recentering = false
    /// DEBUG demo: the fling a finger would leave, through the same offsets.
    private var demo: FlingAnimator?
    /// Where the drag began: every wheel of the drag and its fling is there.
    private var anchor = CGPoint.zero
    /// The touch that stopped a fling (the terminal's tap ignores it).
    private weak var flingStopTouch: UITouch?
    /// Whether the host's tap is the app's click (``TerminalTUITapClick``).
    private var tapClick = TerminalTUITapClick()
    private weak var tap: UITapGestureRecognizer?
    /// Where and when the tap's finger landed (host points, the touch clock).
    private var tapDown: (at: CGPoint, time: TimeInterval)?
    /// The last touch on the host (a selection handle may own it).
    private weak var lastTouch: UITouch?
    /// This drag moves the reader (``readerOpens``), which decelerates itself.
    private var dragsReader = false

    /// `tap`: the host's tap, which a touch that stops a fling does not reach.
    func install(in host: UIView, surface: TerminalSurfaceView, tap: UITapGestureRecognizer) {
        self.surface = surface
        self.tap = tap
        tap.delegate = self
        // Never hit: touches go to the host, whose recognizers include the
        // driver's pan (UIScrollView's own pan, moved, keeps the scroll view
        // as its delegate and target).
        driver.isUserInteractionEnabled = false
        driver.alpha = 0
        driver.frame = host.bounds
        driver.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        driver.delegate = self
        driver.shouldBeginPan = { [weak self] pan in self?.shouldBegin(pan) ?? false }
        host.insertSubview(driver, at: 0)
        host.addGestureRecognizer(driver.panGestureRecognizer)
        recenter()
        // A touch that becomes a drag is never also a tap.
        tap.require(toFail: driver.panGestureRecognizer)
    }

    /// What the host's tap, recognized at `location` (host points), does.
    func tapVerdict(at location: CGPoint) -> TerminalTUITapClick.Verdict {
        guard let tapDown else { return .focusOnly }
        let moved = hypot(location.x - tapDown.at.x, location.y - tapDown.at.y)
        return tapClick.verdict(downAt: tapDown.time, upAt: CACurrentMediaTime(), moved: moved)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        endDemo()
        // A fling the finger caught ends here; the offset stays put under
        // the finger (moving it now would jump the drag).
        endScroll(recenter: false)
        scroll.reset(offset: scrollView.contentOffset.y)
        scrolling = true
        dragBegan()
        // The finger's start, not where the pan recognized.
        if let surface {
            let translation = pan.translation(in: surface)
            let at = pan.location(in: surface)
            anchor = CGPoint(x: at.x - translation.x, y: at.y - translation.y)
            // Toward older rows the phone already has: a plain scroll of them.
            dragsReader = translation.y > 0 && readerOpens()
            if dragsReader { readerMoved(translation.y) }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !recentering else { return }
        if dragsReader {
            scroll.reset(offset: scrollView.contentOffset.y)
            if let surface { readerMoved(pan.translation(in: surface).y) }
            return
        }
        guard let wheel = scroll.scrolled(to: scrollView.contentOffset.y, tracking: scrollView.isTracking),
              scrolling else { return }
        send(wheel)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard dragsReader else { return }
        // The reader decelerates itself; the driver stops where it is.
        targetContentOffset.pointee = scrollView.contentOffset
        endReader(velocityY: surface.map { pan.velocity(in: $0).y } ?? 0)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // A cancelled drag of the reader: it settles where it is.
        if dragsReader { endReader(velocityY: 0) }
        if !decelerate { endScroll() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        endScroll()
    }

    private func send(_ wheel: TerminalTUIScroll.Wheel) {
        guard let surface, isEnabled() else { return }
        let dy = wheel.dy == 0 ? 0 : panHeld(wheel.dy)
        // Painted on the phone: nothing for the app (a fling's end still
        // closes Ghostty's momentum phase, with no rows).
        if dy == 0, wheel.dy != 0, wheel.momentum != .ended { return }
        surface.scrollWheel(at: anchor, deltaY: dy, momentum: wheel.momentum)
        tapClick.scrolled(at: CACurrentMediaTime())
        wheelSent()
    }

    private func endReader(velocityY: CGFloat) {
        dragsReader = false
        if let surface { readerMoved(pan.translation(in: surface).y) }
        readerEnded(velocityY)
    }

    /// The drag or its fling is over: its end goes out once, and the
    /// driver goes back to the middle of its range.
    private func endScroll(recenter again: Bool = true) {
        if let end = scroll.ended() { send(end) }
        if scrolling {
            scrolling = false
            panEnded()
        }
        if again { recenter() }
    }

    /// The driver's offset in the middle of a range no drag reaches the end of.
    private func recenter() {
        recentering = true
        driver.contentSize = CGSize(width: driver.bounds.width, height: TerminalTUIScrollDriver.range)
        driver.contentOffset = CGPoint(x: 0, y: TerminalTUIScrollDriver.range / 2)
        scroll.reset(offset: driver.contentOffset.y)
        recentering = false
    }

    private func endDemo() {
        guard let demo else { return }
        self.demo = nil
        demo.onEnd = nil
        demo.stop()
    }

    /// DEBUG demo: a fling of `velocityY` (points per second, positive
    /// scrolls toward older content) from the surface's middle: the
    /// driver's offset decelerates at UIScrollView's normal rate, through
    /// the same offset-to-wheel path as a finger's fling.
    func demoFling(velocityY: CGFloat) {
        guard let surface, isEnabled() else { return }
        stopMomentum()
        anchor = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        scrolling = true
        dragBegan()
        let animator = FlingAnimator(scrollView: driver, velocity: -velocityY, minY: 0, maxY: TerminalTUIScrollDriver.range)
        animator.onEnd = { [weak self] in
            self?.demo = nil
            self?.endScroll()
        }
        demo = animator
        animator.start()
    }

    /// Whether a fling is running.
    var isFlinging: Bool { driver.isDecelerating || demo != nil }

    /// A touch, a new drag or leaving the app stops a fling (its end goes out once).
    func stopMomentum() {
        endDemo()
        if driver.isDecelerating {
            // Setting the offset where it is ends UIKit's deceleration.
            recentering = true
            driver.setContentOffset(driver.contentOffset, animated: false)
            recentering = false
        }
        if !driver.isTracking { endScroll() }
    }

    // MARK: UIGestureRecognizerDelegate

    // The host tap's delegate (`install`); the pan's is the driver.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // A finger on the screen stops the fling, as in any scroll view.
        if isFlinging {
            stopMomentum()
            flingStopTouch = touch
        }
        lastTouch = touch
        if gestureRecognizer === tap, let view = gestureRecognizer.view {
            tapDown = (touch.location(in: view), touch.timestamp)
        }
        return touch !== flingStopTouch
    }

    /// The driver's pan begins on a vertical drag over the app that no selection owns.
    private func shouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard isEnabled(), !selectionOwns(lastTouch) else { return false }
        // The translation so far (a slow drag can report no velocity yet).
        let moved = pan.translation(in: pan.view)
        return TerminalTUIScroll.takesDrag(motion: moved == .zero ? pan.velocity(in: pan.view) : moved)
    }
}

/// The alternate screen's scroll view: never seen or hit, only its pan (on
/// the host) and its deceleration are used. Its content is far taller than
/// any drag and fling, so its offset never meets an end and never bounces.
final class TerminalTUIScrollDriver: UIScrollView {
    /// The content's height: a fling at 10,000 points a second travels about 5,000.
    static let range: CGFloat = 4_000_000
    var shouldBeginPan: (UIPanGestureRecognizer) -> Bool = { _ in true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bounces = false
        scrollsToTop = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .normal
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // UIScrollView is its pan's delegate (this selector is also the
    // delegate's), so the host's pan asks here.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer, !shouldBeginPan(panGestureRecognizer) { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
#endif

#if os(iOS)
import CmuxScreenKit
import UIKit

/// The remote screen: a zoomable view of the framebuffer, the local cursor,
/// touch gestures and keyboard input. One input model, no modes: a tap
/// clicks where the finger is, press-and-hold then drag drags, one finger
/// pans a zoomed view, two-finger tap right-clicks, two fingers scroll, and
/// pinch zooms (zoom in for small targets).
///
/// Fitted mode (the default) pins the view to one display: zoom out stops at
/// its fit and panning stays inside it. A computer with several displays
/// shows one per page: swipe at fit (or tap the page dots) to switch. With
/// fitted mode off, pinching zooms freely across all displays.
///
/// SwiftUI apps use `ScreenView`; UIKit apps can host this controller directly.
public final class ScreenViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    public let session: ScreenSession
    /// Swipes at fit move between displays (and the page dots show); off
    /// keeps the view on the current display.
    public var allowsDisplayPaging = true {
        didSet { pageControl.alpha = allowsDisplayPaging ? 1 : 0 }
    }

    private let scrollView = UIScrollView()
    private let content = UIView()
    private let screenLayer = CALayer()
    private let cursorLayer = CALayer()
    private var cursor = VNCCursor(width: 0, height: 0, hotspotX: 0, hotspotY: 0, pixels: [])
    private let keyInput = KeyInputView()
    private var frameSize = CGSize.zero
    private var scrollRemainder = CGPoint.zero
    /// Finger travel in points per wheel click.
    private let pointsPerScrollClick: CGFloat = 18
    /// The displays, in framebuffer pixels; empty for one display.
    private var screens: [CGRect] = []
    /// Whether the server reported the layout (then no detection).
    private var screensFromServer = false
    private var page = 0
    /// The view is fitted to `screens[page]` and swipes change page.
    private var paged = false
    private let pageControl = UIPageControl()
    private var lastDetection = CFTimeInterval(0)
    /// Stream mode: the Mac's video, and its displays (each streams on its own).
    private var videoView: ScreenVideoView?
    private var streamDisplays: [CGSize] = []

    public init(session: ScreenSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.delaysContentTouches = false
        view.addSubview(scrollView)
        scrollView.addSubview(content)
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        screenLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        content.layer.addSublayer(screenLayer)
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        cursorLayer.zPosition = 1
        cursorLayer.isHidden = true
        content.layer.addSublayer(cursorLayer)
        keyInput.session = session
        view.addSubview(keyInput)
        installGestures()
        pageControl.isHidden = true
        pageControl.hidesForSinglePage = true
        pageControl.backgroundStyle = .prominent
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if session.isStream {
                session.selectDisplay(pageControl.currentPage)
                return
            }
            show(page: pageControl.currentPage, animated: true)
        }, for: .valueChanged)
        view.addSubview(pageControl)
        NSLayoutConstraint.activate([
            pageControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        session.onFrame = { [weak self] frame in self?.show(frame) }
        if session.isStream { installVideo() }
        session.onCursor = { [weak self] cursor in self?.setCursor(cursor) }
        session.onScreens = { [weak self] screens in
            self?.screensFromServer = true
            self?.setScreens(screens)
        }
    }

    override public var canBecomeFirstResponder: Bool { true }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateZoomLimits(resetToFit: false)
    }

    // MARK: Frames

    /// Stream mode: the video view fills the content; its pixel size is the frame size.
    private func installVideo() {
        let video = ScreenVideoView(frame: content.bounds)
        video.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.insertSubview(video, at: 0)
        videoView = video
        video.onSize = { [weak self] size in self?.applyFrameSize(size) }
        video.onFrame = { [weak self] in self?.session.perf?.streamFrame() }
        session.onVideoTrack = { [weak video] box in video?.attach(box) }
        session.onStreamDisplays = { [weak self] sizes, current in
            guard let self else { return }
            streamDisplays = sizes
            page = current
            pageControl.numberOfPages = sizes.count
            pageControl.currentPage = current
            pageControl.isHidden = sizes.count < 2
        }
    }

    /// A new frame size (VNC framebuffer or video): reset the content and refit.
    private func applyFrameSize(_ size: CGSize) {
        guard size != frameSize, size.width > 0 else { return }
        frameSize = size
        session.setStreamFrameSize(size)
        scrollView.zoomScale = 1
        content.frame = CGRect(origin: .zero, size: size)
        screenLayer.frame = content.bounds
        videoView?.frame = content.bounds
        scrollView.contentSize = size
        updateZoomLimits(resetToFit: true)
    }

    private func show(_ frame: VNCFrame) {
        let size = CGSize(width: frame.width, height: frame.height)
        let copyStart = CACurrentMediaTime()
        guard let image = frame.makeImage() else { return }
        let copyMs = (CACurrentMediaTime() - copyStart) * 1000
        let drawStart = CACurrentMediaTime()
        defer { session.perf?.frame(frame, stats: session.clientStats, copyMs: copyMs, drawMs: (CACurrentMediaTime() - drawStart) * 1000) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if size != frameSize {
            frameSize = size
            scrollView.zoomScale = 1
            content.frame = CGRect(origin: .zero, size: size)
            screenLayer.frame = content.bounds
            scrollView.contentSize = size
            // A new size means a new layout: find the displays again now.
            if !screensFromServer {
                screens = []
                paged = false
                pageControl.isHidden = true
                lastDetection = 0
            }
            updateZoomLimits(resetToFit: true)
        }
        screenLayer.contents = image
        CATransaction.commit()
        updateCursor()
        detectScreens(in: frame)
    }

    private func setCursor(_ cursor: VNCCursor) {
        self.cursor = cursor
        cursorLayer.contents = cursor.makeImage()
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: cursor.width, height: cursor.height)
        updateCursor()
    }

    /// Draws the cursor at the pointer when the server sent a shape (local cursor).
    private func updateCursor() {
        let visible = session.preferences.localCursor && !cursor.isEmpty && frameSize != .zero
        cursorLayer.isHidden = !visible
        guard visible else { return }
        let pointer = session.pointer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = CGPoint(x: pointer.x - CGFloat(cursor.hotspotX) + CGFloat(cursor.width) / 2,
                                       y: pointer.y - CGFloat(cursor.hotspotY) + CGFloat(cursor.height) / 2)
        // Keep the cursor a readable size when zoomed out.
        let scale = max(1, 0.75 / max(scrollView.zoomScale, 0.01))
        cursorLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    // MARK: Displays

    /// Pinned to one display (on by default): zoom out stops at its fit,
    /// panning stays inside it, and a swipe at fit changes display.
    public var fitToDisplay = true {
        didSet {
            guard fitToDisplay != oldValue else { return }
            if fitToDisplay { show(page: page, animated: true) } else { paged = false; updateZoomLimits(resetToFit: false) }
        }
    }

    /// Finds the displays from the pixels, at most once a second (a display
    /// the server paints late is picked up on a later frame).
    private func detectScreens(in frame: VNCFrame) {
        guard !screensFromServer else { return }
        let now = CACurrentMediaTime()
        guard now - lastDetection >= 1 else { return }
        lastDetection = now
        setScreens(VNCScreenLayout().screens(in: frame))
    }

    private func setScreens(_ next: [CGRect]) {
        guard next != screens else { return }
        let first = screens.isEmpty
        screens = next
        pageControl.numberOfPages = next.count
        pageControl.isHidden = next.count < 2
        page = min(page, max(0, next.count - 1))
        // First time: open on the display at the origin (the main display on a Mac).
        if first, next.count > 1 { page = next.firstIndex { $0.origin == .zero } ?? 0 }
        if fitToDisplay || (paged && next.count > 1) {
            show(page: page, animated: !first)
        } else {
            updateZoomLimits(resetToFit: false)
        }
    }

    /// The display the view is pinned to: one of several, or the whole frame.
    private var focusRect: CGRect {
        screens.indices.contains(page) ? screens[page] : CGRect(origin: .zero, size: frameSize)
    }

    private func fitScale(_ rect: CGRect) -> CGFloat {
        guard rect.width > 0, rect.height > 0 else { return 1 }
        return min(view.bounds.width / rect.width, view.bounds.height / rect.height)
    }

    /// The content offset that centers `rect` at `scale`.
    private func centeredOffset(_ rect: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX * scale - (view.bounds.width - rect.width * scale) / 2,
                y: rect.minY * scale - (view.bounds.height - rect.height * scale) / 2)
    }

    /// Fits display `index` to the view.
    private func show(page index: Int, animated: Bool) {
        guard frameSize != .zero, view.bounds.width > 0 else { return }
        page = screens.indices.contains(index) || session.isStream ? index : 0
        paged = true
        pageControl.currentPage = page
        let rect = focusRect
        let scale = fitScale(rect)
        let apply = { [self] in
            scrollView.minimumZoomScale = fitToDisplay ? scale : fitScale(CGRect(origin: .zero, size: frameSize))
            scrollView.maximumZoomScale = max(scale * 6, 2)
            centerContent()
            scrollView.zoomScale = scale
            scrollView.contentOffset = centeredOffset(rect, scale: scale)
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
        updateCursor()
    }

    private var atFit: Bool { abs(scrollView.zoomScale - fitScale(focusRect)) < 0.001 }

    /// The offsets that keep the focused display on screen (centered on an
    /// axis where it is smaller than the view).
    private func clamped(_ offset: CGPoint, allowHorizontal: Bool) -> CGPoint {
        let rect = focusRect, scale = scrollView.zoomScale, bounds = view.bounds.size
        func range(_ minEdge: CGFloat, _ length: CGFloat, _ viewLength: CGFloat) -> ClosedRange<CGFloat> {
            let low = minEdge * scale, size = length * scale
            if size <= viewLength {
                let centered = low - (viewLength - size) / 2
                return centered ... centered
            }
            return low ... low + size - viewLength
        }
        let x = range(rect.minX, rect.width, bounds.width), y = range(rect.minY, rect.height, bounds.height)
        return CGPoint(x: allowHorizontal ? offset.x : min(max(offset.x, x.lowerBound), x.upperBound),
                       y: min(max(offset.y, y.lowerBound), y.upperBound))
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard fitToDisplay, frameSize != .zero else { return }
        // A swipe at fit may move sideways (to page); everything else stays in the display.
        let paging = allowsDisplayPaging && scrollView.isDragging && (screens.count > 1 || streamDisplays.count > 1) && atFit
        let next = clamped(scrollView.contentOffset, allowHorizontal: paging)
        if next != scrollView.contentOffset { scrollView.contentOffset = next }
    }

    /// A swipe that ends at fit moves one display (or snaps back); zoomed in,
    /// panning stops at the display's edges.
    public func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Stream mode: each display is its own video; a swipe at fit asks the Mac for the next one.
        if session.isStream, allowsDisplayPaging, streamDisplays.count > 1, atFit {
            let home = centeredOffset(focusRect, scale: scrollView.zoomScale).x
            let moved = scrollView.contentOffset.x - home
            var target = page
            if velocity.x > 0.3 || moved > view.bounds.width * 0.25 { target = min(page + 1, streamDisplays.count - 1) }
            if velocity.x < -0.3 || moved < -view.bounds.width * 0.25 { target = max(page - 1, 0) }
            targetContentOffset.pointee = scrollView.contentOffset
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if target != page { session.selectDisplay(target) }
                show(page: page, animated: true)
            }
            return
        }
        let pages = allowsDisplayPaging && paged && screens.count > 1 && (atFit || !fitToDisplay)
        guard pages else {
            if fitToDisplay { targetContentOffset.pointee = clamped(targetContentOffset.pointee, allowHorizontal: false) }
            return
        }
        let home = centeredOffset(focusRect, scale: scrollView.zoomScale).x
        let moved = scrollView.contentOffset.x - home
        var target = page
        if velocity.x > 0.3 || moved > view.bounds.width * 0.25 { target = min(page + 1, screens.count - 1) }
        if velocity.x < -0.3 || moved < -view.bounds.width * 0.25 { target = max(page - 1, 0) }
        targetContentOffset.pointee = scrollView.contentOffset
        DispatchQueue.main.async { [weak self] in self?.show(page: target, animated: true) }
    }

    public func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        // Free mode: pinching leaves paging; a page dot brings it back.
        if !fitToDisplay { paged = false }
    }

    // MARK: Zoom

    private func updateZoomLimits(resetToFit: Bool) {
        guard frameSize.width > 0, frameSize.height > 0, view.bounds.width > 0 else { return }
        if fitToDisplay || paged {
            // Re-fit after a rotation or resize; keep a zoomed-in view zoomed.
            let wasAtFit = abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
            if resetToFit || wasAtFit { show(page: page, animated: false) } else {
                scrollView.minimumZoomScale = fitToDisplay ? fitScale(focusRect) : fitScale(CGRect(origin: .zero, size: frameSize))
                centerContent()
            }
            return
        }
        let fit = fitScale(CGRect(origin: .zero, size: frameSize))
        let wasAtFit = abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = max(fit * 6, 2)
        if resetToFit || wasAtFit || scrollView.zoomScale < fit { scrollView.zoomScale = fit }
        centerContent()
    }

    public func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    public func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        if fitToDisplay, !scrollView.isZoomBouncing {
            let next = clamped(scrollView.contentOffset, allowHorizontal: false)
            if next != scrollView.contentOffset { scrollView.contentOffset = next }
        }
        updateCursor()
    }

    /// Insets that let any display sit centered (fitted mode and pages);
    /// otherwise letterboxing for a frame smaller than the view.
    private func centerContent() {
        if fitToDisplay || screens.count > 1 {
            let bounds = scrollView.bounds.size
            scrollView.contentInset = UIEdgeInsets(top: bounds.height, left: bounds.width, bottom: bounds.height, right: bounds.width)
            return
        }
        let width = content.frame.width, height = content.frame.height
        let insetX = max(0, (scrollView.bounds.width - width) / 2)
        let insetY = max(0, (scrollView.bounds.height - height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    // MARK: Gestures

    private let longPress = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let twoFingerPan = UIPanGestureRecognizer()

    private func installGestures() {
        longPress.addTarget(self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 12
        tap.addTarget(self, action: #selector(handleTap(_:)))
        twoFingerTap.addTarget(self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerPan.addTarget(self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        for recognizer in [longPress, tap, twoFingerTap, twoFingerPan] as [UIGestureRecognizer] {
            recognizer.delegate = self
            scrollView.addGestureRecognizer(recognizer)
        }
        // Paging needs one-finger horizontal swipes even when a display fits the view.
        scrollView.alwaysBounceHorizontal = true
        // A hold that becomes a drag wins over panning the view.
        scrollView.panGestureRecognizer.require(toFail: longPress)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch zoom and two-finger scroll may run together.
        (gestureRecognizer == twoFingerPan && other == scrollView.pinchGestureRecognizer)
            || (other == twoFingerPan && gestureRecognizer == scrollView.pinchGestureRecognizer)
    }

    /// A touch location in framebuffer pixels.
    private func framebufferPoint(_ recognizer: UIGestureRecognizer) -> CGPoint {
        recognizer.location(in: content)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            session.movePointer(to: framebufferPoint(recognizer))
            session.press(.left, down: true)
        case .changed:
            session.movePointer(to: framebufferPoint(recognizer))
        case .ended, .cancelled, .failed:
            session.press(.left, down: false)
        default:
            break
        }
        updateCursor()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        session.movePointer(to: framebufferPoint(recognizer))
        session.click(.left)
        updateCursor()
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        session.movePointer(to: framebufferPoint(recognizer))
        session.click(.right)
        updateCursor()
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let velocity = recognizer.translation(in: view)
        recognizer.setTranslation(.zero, in: view)
        if recognizer.state == .began {
            scrollRemainder = .zero
            // Scroll what is under the fingers.
            session.movePointer(to: framebufferPoint(recognizer))
        }
        scrollRemainder.x += velocity.x
        scrollRemainder.y += velocity.y
        let clicksX = Int(scrollRemainder.x / pointsPerScrollClick), clicksY = Int(scrollRemainder.y / pointsPerScrollClick)
        scrollRemainder.x -= CGFloat(clicksX) * pointsPerScrollClick
        scrollRemainder.y -= CGFloat(clicksY) * pointsPerScrollClick
        // Natural scrolling: fingers moving down move the content down (wheel up).
        session.scroll(dx: clicksX, dy: clicksY)
    }

    // MARK: Keyboard

    /// The software keyboard (with its Esc/Tab/arrows/modifier bar).
    public var isKeyboardVisible: Bool {
        get { keyInput.isFirstResponder }
        set {
            if newValue { keyInput.becomeFirstResponder() } else { keyInput.resignFirstResponder(); becomeFirstResponder() }
        }
    }

    /// A hardware keyboard while the software keyboard is hidden.
    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !keyInput.forward(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }
}
#endif

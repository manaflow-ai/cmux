#if os(iOS)
import CmuxScreenKit
import UIKit

/// The remote screen: a zoomable view of the framebuffer, the local cursor,
/// touch gestures and keyboard input. Two input modes (``inputMode``):
/// - direct (the default): a tap clicks where the finger is (two quick taps
///   double-click), press-and-hold then drag drags, one finger pans a
///   zoomed view;
/// - trackpad: one finger moves a cursor (faster strokes go further), a tap
///   clicks at it, tap then hold and drag (or a long press) drags, and a
///   zoomed view follows the cursor.
///
/// Both: two-finger tap right-clicks, two fingers scroll (smoothly, in
/// pixels, when the Mac takes it), pinch zooms. Sticky ⌃⌥⌘ from the keyboard
/// bar modify the next click. On iPad a mouse or trackpad drives the pointer
/// directly: hover moves it, the buttons click and drag, the secondary
/// button right-clicks, the wheel scrolls; the system pointer hides over
/// the screen.
///
/// Fitted mode (the default) pins the view to one display: zoom out stops at
/// its fit and panning stays inside it. A computer with several displays
/// shows one per page: swipe at fit (or tap the page dots) to switch. With
/// fitted mode off, pinching zooms freely across all displays.
///
/// SwiftUI apps use `ScreenView`; UIKit apps can host this controller directly.
public final class ScreenViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate,
    UIPointerInteractionDelegate {
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
    private var hostCursorImage: CGImage?
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
        inputMode = session.preferences.inputMode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // UI tests drive the screen through this element (a query by id stays cheap while it redraws).
        scrollView.accessibilityIdentifier = "screen.view"
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
        applyInputMode()
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
        updateCursor()
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
        hostCursorImage = cursor.makeImage()
        updateCursor()
    }

    /// Draws the cursor at the pointer: the server's shape (local cursor),
    /// and in trackpad mode or under a hovering mouse the shape or, when
    /// the server sends none (a screen stream), a plain arrow.
    private func updateCursor() {
        let hostShape = !cursor.isEmpty && (session.preferences.localCursor || inputMode == .trackpad)
        let visible = frameSize != .zero && (hostShape || inputMode == .trackpad || pointerHovering)
        cursorLayer.isHidden = !visible
        guard visible else { return }
        let fallback = Self.fallbackCursor
        let image = hostShape ? hostCursorImage : fallback.image
        let size = hostShape ? CGSize(width: cursor.width, height: cursor.height) : fallback.size
        let hotspot = hostShape ? CGPoint(x: cursor.hotspotX, y: cursor.hotspotY) : fallback.hotspot
        let pointer = session.pointer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if (cursorLayer.contents as AnyObject?) !== image {
            cursorLayer.contents = image
            cursorLayer.bounds = CGRect(origin: .zero, size: size)
        }
        cursorLayer.position = CGPoint(x: pointer.x - hotspot.x + size.width / 2, y: pointer.y - hotspot.y + size.height / 2)
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

    // MARK: Input mode

    /// How touches drive the pointer (`ScreenPreferences.inputMode`):
    /// direct (a tap clicks where the finger is) or trackpad (a cursor one
    /// finger moves). Applies at once; a held button or drag is released.
    public var inputMode: ScreenInputMode {
        didSet { if inputMode != oldValue { applyInputMode() } }
    }

    private func applyInputMode() {
        let trackpadMode = inputMode == .trackpad
        applyTrackpad(trackpad.cancel())
        trackpadTimer?.cancel()
        trackpadTimer = nil
        tap.isEnabled = !trackpadMode
        longPress.isEnabled = !trackpadMode
        trackpadTouch.isEnabled = trackpadMode
        // Trackpad mode: one finger moves the cursor, not the view (the view follows the cursor).
        scrollView.panGestureRecognizer.isEnabled = !trackpadMode
        updateCursor()
        followCursor()
    }

    // MARK: Gestures

    private let longPress = UILongPressGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let twoFingerPan = UIPanGestureRecognizer()
    /// Trackpad mode's one finger.
    private let trackpadTouch = SingleTouchRecognizer(target: nil, action: nil)
    /// A mouse or trackpad on iPad: buttons, hover and the scroll wheel.
    private let pointerButtons = PointerButtonRecognizer(target: nil, action: nil)
    private let hover = UIHoverGestureRecognizer()
    private let wheel = UIPanGestureRecognizer()
    private var trackpad = TrackpadGesture()
    private var trackpadTimer: Task<Void, Never>?
    private var lastTrackpadPoint: CGPoint?
    private let acceleration = PointerAcceleration()
    /// Direct mode: a double tap clicks twice at one point.
    private var clickSnap = ClickSnap()
    /// The sticky ⌃⌥⌘ held down for the press in progress (a drag, a trackpad click).
    private var heldModifiers: [VNCKeysym] = []
    /// The mouse button held on iPad.
    private var pointerButton: VNCButtons?
    /// A hardware pointer is over the screen (the system pointer is hidden there).
    private var pointerHovering = false

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
        trackpadTouch.onEvent = { [weak self] event in self?.handleTrackpad(event) }
        trackpadTouch.isEnabled = false
        pointerButtons.onEvent = { [weak self] event in self?.handlePointerButton(event) }
        hover.addTarget(self, action: #selector(handleHover(_:)))
        wheel.addTarget(self, action: #selector(handleWheel(_:)))
        // Scroll events only (a mouse wheel, two fingers on a trackpad), no touches.
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        // Fingers and the pencil; a mouse button is pointerButtons' (it drags at once, no hold).
        let touches = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        for recognizer in [longPress, tap, twoFingerTap, twoFingerPan, trackpadTouch] as [UIGestureRecognizer] {
            recognizer.allowedTouchTypes = touches
        }
        scrollView.panGestureRecognizer.allowedTouchTypes = touches
        // Wheel scrolling scrolls the Mac, not this view.
        scrollView.panGestureRecognizer.allowedScrollTypesMask = []
        for recognizer in [longPress, tap, twoFingerTap, twoFingerPan, trackpadTouch, pointerButtons, hover, wheel] as [UIGestureRecognizer] {
            recognizer.delegate = self
            scrollView.addGestureRecognizer(recognizer)
        }
        scrollView.addInteraction(UIPointerInteraction(delegate: self))
        // Paging needs one-finger horizontal swipes even when a display fits the view.
        scrollView.alwaysBounceHorizontal = true
        // A hold that becomes a drag wins over panning the view.
        scrollView.panGestureRecognizer.require(toFail: longPress)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The trackpad finger, the hardware pointer and hover only observe: they run beside everything.
        let observers: [UIGestureRecognizer] = [trackpadTouch, pointerButtons, hover]
        if observers.contains(gestureRecognizer) || observers.contains(other) { return true }
        // Pinch zoom and two-finger scroll may run together.
        return (gestureRecognizer == twoFingerPan && other == scrollView.pinchGestureRecognizer)
            || (other == twoFingerPan && gestureRecognizer == scrollView.pinchGestureRecognizer)
    }

    /// A touch location in framebuffer pixels.
    private func framebufferPoint(_ recognizer: UIGestureRecognizer) -> CGPoint {
        recognizer.location(in: content)
    }

    /// Framebuffer pixels under one point of the view.
    private var pixelsPerPoint: CGFloat { 1 / max(scrollView.zoomScale, 0.01) }

    /// Presses `button` with the sticky modifiers down first (held until `releaseButton`).
    private func pressButton(_ button: VNCButtons) {
        if heldModifiers.isEmpty {
            heldModifiers = keyInput.takeModifiers()
            for modifier in heldModifiers { session.key(modifier, down: true) }
        }
        session.press(button, down: true)
    }

    private func releaseModifiers() {
        for modifier in heldModifiers.reversed() { session.key(modifier, down: false) }
        heldModifiers = []
    }

    // MARK: Direct touch

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            session.movePointer(to: framebufferPoint(recognizer))
            pressButton(.left)
        case .changed:
            session.movePointer(to: framebufferPoint(recognizer))
        case .ended, .cancelled, .failed:
            session.press(.left, down: false)
            releaseModifiers()
        default:
            break
        }
        updateCursor()
    }

    /// Clicks at once on touch-up (no double-tap recognizer waits): two
    /// quick taps are two clicks at one point, which the Mac counts as a
    /// double click.
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = clickSnap.point(for: framebufferPoint(recognizer), at: CACurrentMediaTime(), radius: 24 * pixelsPerPoint)
        session.movePointer(to: point)
        session.click(.left, modifiers: keyInput.takeModifiers())
        updateCursor()
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        // Trackpad mode: at the cursor.
        if inputMode == .direct { session.movePointer(to: framebufferPoint(recognizer)) }
        session.click(.right, modifiers: keyInput.takeModifiers())
        updateCursor()
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        recognizer.setTranslation(.zero, in: view)
        if recognizer.state == .began {
            scrollRemainder = .zero
            // Scroll what is under the fingers (trackpad mode: under the cursor).
            if inputMode == .direct { session.movePointer(to: framebufferPoint(recognizer)) }
        }
        scroll(by: translation)
    }

    /// Scrolls by a finger's travel in view points: in pixels where the Mac
    /// takes them (smooth), else in wheel lines.
    private func scroll(by translation: CGPoint) {
        // Natural scrolling: fingers moving down move the content down (wheel up).
        scrollRemainder.x += translation.x
        scrollRemainder.y += translation.y
        if session.supportsPixelScroll {
            // The content follows the fingers: their travel in framebuffer pixels.
            let scale = pixelsPerPoint
            let pixelsX = Int(scrollRemainder.x * scale), pixelsY = Int(scrollRemainder.y * scale)
            scrollRemainder.x -= CGFloat(pixelsX) / scale
            scrollRemainder.y -= CGFloat(pixelsY) / scale
            session.scrollPixels(dx: pixelsX, dy: pixelsY)
            return
        }
        let clicksX = Int(scrollRemainder.x / pointsPerScrollClick), clicksY = Int(scrollRemainder.y / pointsPerScrollClick)
        scrollRemainder.x -= CGFloat(clicksX) * pointsPerScrollClick
        scrollRemainder.y -= CGFloat(clicksY) * pointsPerScrollClick
        session.scroll(dx: clicksX, dy: clicksY)
    }

    // MARK: Trackpad mode

    private func handleTrackpad(_ event: SingleTouchRecognizer.Event) {
        switch event {
        case let .down(point, time):
            lastTrackpadPoint = point
            applyTrackpad(trackpad.touchDown(at: time))
        case let .moved(point, time):
            guard let last = lastTrackpadPoint else { return }
            lastTrackpadPoint = point
            applyTrackpad(trackpad.touchMoved(dx: point.x - last.x, dy: point.y - last.y, at: time))
        case let .up(time):
            lastTrackpadPoint = nil
            applyTrackpad(trackpad.touchUp(at: time))
        case .cancelled:
            lastTrackpadPoint = nil
            applyTrackpad(trackpad.cancel())
        }
        scheduleTrackpadDeadline()
    }

    private func applyTrackpad(_ actions: [TrackpadGesture.Action]) {
        guard !actions.isEmpty else { return }
        for action in actions {
            switch action {
            case let .move(dx, dy, dt):
                let delta = acceleration.delta(dx: dx, dy: dy, dt: dt, pixelsPerPoint: pixelsPerPoint)
                let pointer = session.pointer
                session.movePointer(to: clampedToFocus(CGPoint(x: pointer.x + delta.dx, y: pointer.y + delta.dy)))
                followCursor()
            case .press:
                pressButton(.left)
            case .release:
                session.press(.left, down: false)
            }
        }
        // The modifiers stay down across a double click and a drag, and go up when the gesture ends.
        if !trackpad.buttonHeld { releaseModifiers() }
        updateCursor()
    }

    /// Wakes the gesture at its deadline (a long press, the end of a tap's drag window).
    private func scheduleTrackpadDeadline() {
        trackpadTimer?.cancel()
        trackpadTimer = nil
        guard let deadline = trackpad.deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        trackpadTimer = Task { [weak self] in
            // Intentional bounded delay (at most the long-press time): cancelled by the next touch.
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let actions = trackpad.advance(to: ProcessInfo.processInfo.systemUptime)
            if actions.contains(.press) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            applyTrackpad(actions)
            scheduleTrackpadDeadline()
        }
    }

    /// A pointer position kept on the focused display (fitted mode) or the frame.
    private func clampedToFocus(_ point: CGPoint) -> CGPoint {
        let rect = fitToDisplay ? focusRect : CGRect(origin: .zero, size: frameSize)
        return CGPoint(x: min(max(point.x, rect.minX), max(rect.minX, rect.maxX - 1)),
                       y: min(max(point.y, rect.minY), max(rect.minY, rect.maxY - 1)))
    }

    /// Trackpad mode, zoomed in: scrolls the view so the cursor stays clear of its edges.
    private func followCursor() {
        guard inputMode == .trackpad, frameSize != .zero, view.bounds.width > 0 else { return }
        let zoom = scrollView.zoomScale, bounds = scrollView.bounds.size
        let cursor = CGPoint(x: session.pointer.x * zoom, y: session.pointer.y * zoom)
        let margin = min(bounds.width, bounds.height) * 0.12
        var offset = scrollView.contentOffset
        func follow(_ position: CGFloat, _ origin: inout CGFloat, _ length: CGFloat) {
            if position - origin < margin { origin = position - margin } else if position - origin > length - margin { origin = position - length + margin }
        }
        follow(cursor.x, &offset.x, bounds.width)
        follow(cursor.y, &offset.y, bounds.height)
        if fitToDisplay {
            offset = clamped(offset, allowHorizontal: false)
        } else {
            let inset = scrollView.contentInset, size = scrollView.contentSize
            offset.x = min(max(offset.x, -inset.left), max(-inset.left, size.width + inset.right - bounds.width))
            offset.y = min(max(offset.y, -inset.top), max(-inset.top, size.height + inset.bottom - bounds.height))
        }
        if offset != scrollView.contentOffset { scrollView.contentOffset = offset }
    }

    public func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        followCursor()
    }

    // MARK: Mouse and trackpad (iPad)

    /// The pointer follows a hovering mouse (both modes).
    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            pointerHovering = true
            session.movePointer(to: framebufferPoint(recognizer))
        default:
            pointerHovering = false
        }
        updateCursor()
    }

    /// A mouse button: down and up where the pointer is, dragging in between;
    /// the secondary button right-clicks.
    private func handlePointerButton(_ event: PointerButtonRecognizer.Event) {
        switch event {
        case let .down(touch, secondary):
            let button: VNCButtons = secondary ? .right : .left
            if let held = pointerButton { session.press(held, down: false) }
            pointerButton = button
            session.movePointer(to: touch.location(in: content))
            pressButton(button)
        case let .moved(touch):
            session.movePointer(to: touch.location(in: content))
        case .up:
            if let held = pointerButton { session.press(held, down: false) }
            pointerButton = nil
            releaseModifiers()
        }
        updateCursor()
    }

    /// A mouse wheel or two fingers on a trackpad: scrolls the Mac at the pointer.
    @objc private func handleWheel(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        recognizer.setTranslation(.zero, in: view)
        if recognizer.state == .began {
            scrollRemainder = .zero
            session.movePointer(to: framebufferPoint(recognizer))
        }
        scroll(by: translation)
    }

    /// The system pointer hides over the screen: the Mac's cursor (or the drawn one) shows instead.
    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
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

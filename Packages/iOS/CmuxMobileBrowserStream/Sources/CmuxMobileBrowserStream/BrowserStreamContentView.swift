#if canImport(UIKit)
import CMUXMobileCore
import UIKit
import QuartzCore

/// Layer-backed remote browser mirror with native scroll mechanics and a local zoom lens.
@MainActor
final class BrowserStreamContentView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    weak var delegate: (any BrowserStreamContentViewDelegate)?
    var panelID = ""

    private let imageLayer = CALayer()
    private let scrollContentHeight: CGFloat = 1_000_000
    private var isRecentering = false
    private var lastScrollOffset = CGPoint.zero
    private var lastAnchor = CGPoint.zero
    private var scrollBatcher = BrowserStreamScrollBatcher()
    private var pageSize = CGSize.zero
    // Identity of the installed CGImage, not its sequence: sequences restart
    // at one on re-subscription, so a sequence guard could skip the first
    // frame of a new stream that collides with the old stream's counter.
    private var displayedImageID: ObjectIdentifier?
    private var zoomScale: CGFloat = 1
    private var viewportOffset = CGPoint.zero
    private var pinchStartScale: CGFloat = 1
    private var panStartOffset = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var viewportPolicy = BrowserStreamViewportEmissionPolicy()

    private lazy var scrollMechanicsView: UIScrollView = {
        let view = UIScrollView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = true
        view.bounces = true
        view.decelerationRate = .normal
        view.delaysContentTouches = false
        view.canCancelContentTouches = true
        view.scrollsToTop = false
        view.contentInsetAdjustmentBehavior = .never
        view.panGestureRecognizer.cancelsTouchesInView = false
        view.delegate = self
        return view
    }()

    private lazy var inputProxy: BrowserStreamInputView = {
        let view = BrowserStreamInputView(frame: .zero)
        view.onText = { [weak self] text in self?.emitText(text) }
        view.onKey = { [weak self] key in self?.emitKey(key) }
        return view
    }()

    private lazy var localPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleLocalPan(_:)))

    /// Creates an empty stream surface.
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.055, green: 0.063, blue: 0.075, alpha: 1)
        clipsToBounds = true
        isOpaque = true
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer.addSublayer(imageLayer)
        addSubview(scrollMechanicsView)
        addSubview(inputProxy)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        localPanGesture.delegate = self
        addGestureRecognizer(localPanGesture)
        updateGestureModes()
        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // No deinit: the display-link proxy self-invalidates once its weak target
    // (this view) deallocates, and `didMoveToWindow` pauses the link while the
    // view is detached, so nonisolated deinit never has to touch CADisplayLink.

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.isPaused = window == nil
        recordViewportIfPossible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollMechanicsView.frame = bounds
        scrollMechanicsView.contentSize = CGSize(
            width: max(scrollContentHeight, bounds.width * 8),
            height: max(scrollContentHeight, bounds.height * 8)
        )
        recenter(force: lastScrollOffset == .zero)
        inputProxy.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        layoutImageLayer()
        recordViewportIfPossible()
    }

    /// Installs one decoded frame into the backing layer.
    ///
    /// `updateUIView` re-runs on every observed state change, not only on new
    /// frames, so unchanged sequences return early instead of re-setting layer
    /// contents.
    /// - Parameter frame: The frame to display.
    func display(_ frame: BrowserStreamFrame) {
        guard ObjectIdentifier(frame.image) != displayedImageID else { return }
        displayedImageID = ObjectIdentifier(frame.image)
        pageSize = frame.pageSize
        imageLayer.contents = frame.image
        imageLayer.contentsScale = CGFloat(frame.pixelSize.width / max(frame.pageSize.width, 1))
        layoutImageLayer()
    }

    /// Synchronizes hidden-input focus with the page and manual chrome policy.
    /// - Parameter shouldFocus: Whether the proxy should hold first responder.
    func setInputFocused(_ shouldFocus: Bool) {
        if shouldFocus, !inputProxy.isFirstResponder {
            inputProxy.becomeFirstResponder()
        } else if !shouldFocus, inputProxy.isFirstResponder {
            inputProxy.resignFirstResponder()
        }
    }

    func flushPendingDisplayLinkWork() {
        if zoomScale == 1, let batch = scrollBatcher.next() {
            let transform = currentTransform
            let pageDelta = transform.pageDelta(fromViewDelta: batch.delta)
            let anchor = transform.pagePoint(fromViewPoint: lastAnchor)
                ?? CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
            let input = MobileBrowserScrollInput(
                panelID: panelID,
                deltaX: Double(-pageDelta.x),
                deltaY: Double(-pageDelta.y),
                phase: batch.phase,
                x: Double(anchor.x),
                y: Double(anchor.y)
            )
            delegate?.browserStreamContentView(self, didProduceScroll: input)
        }
        if let viewport = viewportPolicy.takePending() {
            delegate?.browserStreamContentView(self, didChangeViewport: viewport)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        lastAnchor = scrollView.panGestureRecognizer.location(in: self)
        scrollBatcher.consume(.trackingBegan)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === scrollMechanicsView, !isRecentering, zoomScale == 1 else { return }
        let offset = scrollView.contentOffset
        let delta = CGPoint(x: offset.x - lastScrollOffset.x, y: offset.y - lastScrollOffset.y)
        lastScrollOffset = offset
        if scrollView.isTracking || scrollView.isDragging {
            lastAnchor = scrollView.panGestureRecognizer.location(in: self)
        }
        scrollBatcher.consume(
            scrollView.isDecelerating ? .momentumChanged : .trackingChanged,
            delta: delta
        )
        recenter()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        scrollBatcher.consume(.trackingEnded(willDecelerate: decelerate))
    }

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        scrollBatcher.consume(.momentumBegan)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollBatcher.consume(.momentumEnded)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === localPanGesture && zoomScale > 1
    }

    private var currentTransform: BrowserStreamTransform {
        BrowserStreamTransform(
            viewSize: bounds.size,
            pageSize: pageSize,
            zoomScale: zoomScale,
            viewportOffset: viewportOffset
        )
    }

    private func layoutImageLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = currentTransform.displayedPageRect
        CATransaction.commit()
    }

    private func startDisplayLink() {
        let proxy = BrowserStreamDisplayLinkProxy(target: self)
        let link = CADisplayLink(
            target: proxy,
            selector: #selector(BrowserStreamDisplayLinkProxy.fire)
        )
        proxy.link = link
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func recordViewportIfPossible() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let scale = traitCollection.displayScale > 0
            ? traitCollection.displayScale
            : window?.screen.scale ?? 1
        viewportPolicy.record(MobileBrowserViewport(
            width: Int(bounds.width.rounded(.toNearestOrAwayFromZero)),
            height: Int(bounds.height.rounded(.toNearestOrAwayFromZero)),
            scale: Double(scale)
        ))
    }

    private func recenter(force: Bool = false) {
        let size = scrollMechanicsView.contentSize
        let offset = scrollMechanicsView.contentOffset
        let margin = max(bounds.width, bounds.height) * 2
        guard force || offset.x < margin || offset.y < margin
            || offset.x > size.width - bounds.width - margin
            || offset.y > size.height - bounds.height - margin else { return }
        let centered = CGPoint(
            x: max(0, (size.width - bounds.width) / 2),
            y: max(0, (size.height - bounds.height) / 2)
        )
        isRecentering = true
        scrollMechanicsView.setContentOffset(centered, animated: false)
        lastScrollOffset = centered
        isRecentering = false
    }

    private func updateGestureModes() {
        let zoomed = zoomScale > 1.001
        if zoomed { scrollBatcher.reset() }
        scrollMechanicsView.isScrollEnabled = !zoomed
        localPanGesture.isEnabled = zoomed
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let point = currentTransform.pagePoint(fromViewPoint: gesture.location(in: self)) else { return }
        let input = MobileBrowserPointerInput(
            panelID: panelID,
            kind: .click,
            x: Double(point.x),
            y: Double(point.y),
            clickCount: 1,
            button: .left
        )
        delegate?.browserStreamContentView(self, didProducePointer: input)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.001 {
            zoomScale = 1
            viewportOffset = .zero
        } else {
            zoomScale = 2
            let location = gesture.location(in: self)
            viewportOffset = CGPoint(
                x: (location.x - bounds.midX) * (zoomScale - 1),
                y: (location.y - bounds.midY) * (zoomScale - 1)
            )
        }
        updateGestureModes()
        layoutImageLayer()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinchStartScale = zoomScale }
        zoomScale = min(max(1, pinchStartScale * gesture.scale), 4)
        if zoomScale <= 1.001 { zoomScale = 1; viewportOffset = .zero }
        updateGestureModes()
        layoutImageLayer()
    }

    @objc private func handleLocalPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { panStartOffset = viewportOffset }
        let translation = gesture.translation(in: self)
        viewportOffset = CGPoint(x: panStartOffset.x - translation.x, y: panStartOffset.y - translation.y)
        layoutImageLayer()
    }

    private func emitText(_ text: String) {
        delegate?.browserStreamContentView(
            self,
            didProduceText: MobileBrowserTextInput(panelID: panelID, text: text)
        )
    }

    private func emitKey(_ key: String) {
        delegate?.browserStreamContentView(
            self,
            didProduceKey: MobileBrowserKeyInput(panelID: panelID, key: key, modifiers: [])
        )
    }
}
#endif

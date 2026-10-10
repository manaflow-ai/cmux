#if canImport(UIKit)
import CmuxConversationGeometry
import UIKit

/// Messages' full-screen photo viewer (measured on iOS 26.5): the photo
/// aspect-fits on the system background under a "Photo" title with a glass
/// close button at the trailing edge; the bottom bar holds Tapback and Reply
/// (a glass capsule, leading) and Share (a glass circle, trailing). A tap
/// hides the chrome and turns the background black; pinch and double-tap
/// zoom; dragging down shrinks the photo and fades the background, and
/// letting go flies it back into its bubble.
final class ConversationPhotoViewerController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let image: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let backdrop = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let actionsBar = UIView()
    private let tapbackButton = UIButton(type: .system)
    private let replyButton = UIButton(type: .system)
    private var chromeHidden = false
    private var dragStart: CGPoint?
    /// Tapback and Reply act on the photo's message once the viewer closes.
    var onTapback: (() -> Void)?
    var onReply: (() -> Void)?

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredStatusBarStyle: UIStatusBarStyle { chromeHidden ? .lightContent : .default }

    /// The photo's on-screen view, the zoom flight's end point.
    var photoView: UIImageView { imageView }

    /// 0...1: how much of the viewer (background and chrome) shows, for the
    /// zoom flight and the drag to dismiss.
    var presentationProgress: CGFloat = 1 {
        didSet {
            backdrop.alpha = presentationProgress
            let chrome = chromeHidden ? 0 : presentationProgress
            for view in chromeViews { view.alpha = chrome }
        }
    }

    private var chromeViews: [UIView] { [titleLabel, closeButton, shareButton, actionsBar] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "conversation.photoViewer"
        backdrop.backgroundColor = .systemBackground
        view.addSubview(backdrop)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module)
        scrollView.addSubview(imageView)

        titleLabel.text = String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        view.addSubview(titleLabel)

        let symbols = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        configure(closeButton, symbol: "xmark", symbols: symbols, label: String(localized: "conversation.photoViewer.close", defaultValue: "Close", bundle: .module), id: "conversation.photoViewer.close")
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        configure(shareButton, symbol: "square.and.arrow.up", symbols: symbols, label: String(localized: "conversation.photoViewer.share", defaultValue: "Share", bundle: .module), id: "conversation.photoViewer.share")
        shareButton.addAction(UIAction { [weak self] _ in self?.share() }, for: .touchUpInside)

        // Tapback and Reply share one glass capsule, as in Messages.
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.isUserInteractionEnabled = false
            actionsBar.addSubview(glass)
        } else {
            actionsBar.backgroundColor = .secondarySystemBackground
        }
        actionsBar.clipsToBounds = true
        let actions: [(UIButton, String, String, String)] = [
            (tapbackButton, "plus.bubble", String(localized: "conversation.photoViewer.tapback", defaultValue: "Tapback", bundle: .module), "conversation.photoViewer.tapback"),
            (replyButton, "arrowshape.turn.up.left", String(localized: "conversation.photoViewer.reply", defaultValue: "Reply", bundle: .module), "conversation.photoViewer.reply"),
        ]
        for (button, symbol, label, id) in actions {
            button.setImage(UIImage(systemName: symbol, withConfiguration: symbols), for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = label
            button.accessibilityIdentifier = id
            actionsBar.addSubview(button)
        }
        tapbackButton.addAction(UIAction { [weak self] _ in self?.closeThen(self?.onTapback) }, for: .touchUpInside)
        replyButton.addAction(UIAction { [weak self] _ in self?.closeThen(self?.onReply) }, for: .touchUpInside)
        view.addSubview(actionsBar)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(tap)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.delegate = self
        drag.name = "conversation.photoViewer.dismissDrag"
        view.addGestureRecognizer(drag)
    }

    private func configure(_ button: UIButton, symbol: String, symbols: UIImage.SymbolConfiguration, label: String, id: String) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: symbols), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        if #available(iOS 26.0, *) {
            var configuration = UIButton.Configuration.glass()
            configuration.image = button.image(for: .normal)
            configuration.baseForegroundColor = .label
            configuration.cornerStyle = .capsule
            button.configuration = configuration
        }
        view.addSubview(button)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds
        scrollView.frame = view.bounds
        if scrollView.zoomScale == 1, dragStart == nil {
            imageView.frame = fittedFrame(in: view.bounds)
            scrollView.contentSize = view.bounds.size
        }
        let safe = view.safeAreaInsets
        let width = view.bounds.width
        // Measured in Messages (402 x 874 pt): a 44 pt close button 16 pt in
        // from the trailing edge at the safe-area top, the title centered on
        // it, and 48 pt bottom controls whose centers sit 52 pt above the
        // bottom edge (the Tapback/Reply capsule is 111 pt wide, 28 pt in).
        closeButton.frame = CGRect(x: width - 16 - 44, y: safe.top, width: 44, height: 44)
        titleLabel.frame = CGRect(x: 76, y: safe.top, width: width - 152, height: 44)
        let barMidY = view.bounds.height - 52
        shareButton.frame = CGRect(x: width - 28 - 48, y: barMidY - 24, width: 48, height: 48)
        actionsBar.frame = CGRect(x: 28, y: barMidY - 24, width: 111, height: 48)
        actionsBar.layer.cornerRadius = 24
        actionsBar.subviews.first { $0 is UIVisualEffectView }?.frame = actionsBar.bounds
        tapbackButton.frame = CGRect(x: 6, y: 0, width: 48, height: 48)
        replyButton.frame = CGRect(x: 57, y: 0, width: 48, height: 48)
        actionsBar.isHidden = onTapback == nil && onReply == nil
    }

    private func fittedFrame(in bounds: CGRect) -> CGRect {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep a zoomed-out photo centered.
        let content = imageView.frame.size
        let insetX = max(0, (scrollView.bounds.width - content.width) / 2)
        let insetY = max(0, (scrollView.bounds.height - content.height) / 2)
        imageView.frame.origin = CGPoint(x: insetX, y: insetY)
        scrollView.contentSize = CGSize(width: max(content.width, scrollView.bounds.width), height: max(content.height, scrollView.bounds.height))
    }

    private var isZoomed: Bool { scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 }

    @objc private func tapped() {
        chromeHidden.toggle()
        UIView.animate(withDuration: 0.25) {
            self.backdrop.backgroundColor = self.chromeHidden ? .black : .systemBackground
            for view in self.chromeViews { view.alpha = self.chromeHidden ? 0 : 1 }
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if isZoomed {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = tap.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    // MARK: Drag to dismiss

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.name == "conversation.photoViewer.dismissDrag" else { return true }
        guard !isZoomed else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        switch pan.state {
        case .began:
            dragStart = imageView.center
        case .changed:
            guard let start = dragStart else { return }
            // The photo follows the finger and shrinks toward 70% over a
            // third of the screen; the background fades with it.
            let progress = min(1, max(0, translation.y) / (view.bounds.height / 3))
            let scale = 1 - 0.3 * progress
            imageView.center = CGPoint(x: start.x + translation.x, y: start.y + translation.y)
            imageView.transform = CGAffineTransform(scaleX: scale, y: scale)
            presentationProgress = 1 - progress
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: view).y
            if pan.state == .ended, translation.y > 80 || velocity > 600 {
                dismiss(animated: true)
            } else {
                let start = dragStart
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                    if let start { self.imageView.center = start }
                    self.imageView.transform = .identity
                    self.presentationProgress = 1
                } completion: { _ in
                    self.dragStart = nil
                }
            }
        default:
            break
        }
    }

    private func closeThen(_ action: (() -> Void)?) {
        dismiss(animated: true) { action?() }
    }

    private func share() {
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }
}

/// Where a photo flies from and back to: its bubble view and outline.
struct ConversationPhotoSource {
    weak var view: UIView?
    var side: BubbleShape.Side
    /// The last photo of a run carries the tail, below the full-height photo.
    var tailed: Bool
}

/// The zoom between a photo bubble and the viewer, as Messages draws it:
/// the photo flies on a critically damped spring while its outline morphs
/// continuously between the bubble (continuous corners and tail) and the
/// square full-screen photo. The bubble's own image hides for the flight,
/// so nothing square ever shows behind it.
@MainActor
final class ConversationPhotoZoomTransition: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {
    let source: ConversationPhotoSource
    private var presenting = true

    init(source: ConversationPhotoSource) {
        self.source = source
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        self.presenting = true
        return self
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        self.presenting = false
        return self
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        ConversationPhotoFlight.settleTime
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        if presenting, let to = context.view(forKey: .to), let toController = context.viewController(forKey: .to) {
            to.frame = context.finalFrame(for: toController)
            container.addSubview(to)
            to.layoutIfNeeded()
        }
        guard let viewer = context.viewController(forKey: key) as? ConversationPhotoViewerController,
              let sourceView = source.view, sourceView.window != nil else {
            context.completeTransition(!context.transitionWasCancelled)
            return
        }
        let bubbleFrame = sourceView.convert(sourceView.bounds, to: container)
        let photoFrame = viewer.photoView.convert(viewer.photoView.bounds, to: container)
        let flight = ConversationPhotoFlightView(image: viewer.photoView.image, side: source.side, tailed: source.tailed)
        container.addSubview(flight)
        let startProgress = presenting ? 0 : viewer.presentationProgress
        sourceView.isHidden = true
        viewer.photoView.isHidden = true
        let presenting = presenting
        let from = presenting ? bubbleFrame : photoFrame
        let to = presenting ? photoFrame : bubbleFrame
        let radius = ConversationTheme.bubbleCornerRadius
        let apply: (CGFloat) -> Void = { p in
            flight.place(frame: ConversationPhotoFlight.interpolate(from, to, p), radius: radius * (presenting ? 1 - p : p))
            viewer.presentationProgress = presenting ? p : startProgress * (1 - p)
        }
        apply(0)
        let driver = ConversationPhotoFlightDriver(step: apply) {
            sourceView.isHidden = false
            viewer.photoView.isHidden = false
            flight.removeFromSuperview()
            context.completeTransition(!context.transitionWasCancelled)
        }
        driver.start()
    }
}

/// The flying photo: aspect-fills its frame, clipped to a bubble outline
/// whose corner radius (and tail) follows `radius` every frame.
final class ConversationPhotoFlightView: UIView {
    private let imageView = UIImageView()
    private let outline = CAShapeLayer()
    private let side: ConversationBubbleGeometry.Side
    private let tailed: Bool

    init(image: UIImage?, side: BubbleShape.Side, tailed: Bool) {
        self.side = side == .leading ? .leading : .trailing
        self.tailed = tailed
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        layer.mask = outline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func place(frame: CGRect, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        imageView.frame = bounds
        outline.frame = bounds
        outline.path = ConversationPhotoFlight.outline(in: bounds, radius: radius, side: side, tailed: tailed)
        CATransaction.commit()
    }
}

/// Steps the flight spring from 0 to 1 once per display frame.
@MainActor
final class ConversationPhotoFlightDriver: NSObject {
    private let step: (CGFloat) -> Void
    private let completion: () -> Void
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var retainSelf: ConversationPhotoFlightDriver?

    init(step: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.step = step
        self.completion = completion
    }

    func start() {
        retainSelf = self
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if startTime == nil { startTime = link.timestamp }
        let t = link.targetTimestamp - (startTime ?? link.timestamp)
        if t >= ConversationPhotoFlight.settleTime {
            step(1)
            link.invalidate()
            self.link = nil
            completion()
            retainSelf = nil
        } else {
            step(ConversationPhotoFlight.progress(at: t))
        }
    }
}
#endif

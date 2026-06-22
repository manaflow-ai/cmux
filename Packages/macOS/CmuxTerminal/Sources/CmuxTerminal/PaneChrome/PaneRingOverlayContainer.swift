public import AppKit
public import CmuxTerminalCore

/// The terminal pane's ring/flash overlay chrome, decoupled from the pane
/// container.
///
/// Owns the notification-ring and attention-flash overlay `NSView`s and their
/// `CAShapeLayer`s. The pane container holds one of these as a child view and
/// drives it only through ``TerminalPaneChromeHosting`` set-state calls; it
/// never touches the overlay views or layers directly. The container resolves
/// all colors/metrics in the app target into `Sendable`
/// ``TerminalPaneRingPresentation`` values, so this view never reaches back into
/// app-target presentation types.
///
/// This view is purely additive and never hit-tests, so it can sit above the
/// terminal surface without intercepting clicks or keystrokes.
@MainActor
public final class PaneRingOverlayContainer: NSView, TerminalPaneChromeHosting {
    private let notificationRingOverlayView = PaneOverlayPassthroughView(frame: .zero)
    private let notificationRingLayer = CAShapeLayer()
    private let flashOverlayView = PaneOverlayPassthroughView(frame: .zero)
    private let flashLayer = CAShapeLayer()
    private var lastFlashStyle: TerminalPaneFlashStyle = .navigation
    private var lastFlashPresentation = TerminalPaneRingPresentation.zero
    private var notificationRingPresentation = TerminalPaneRingPresentation.zero

    /// Creates the overlay container and builds its ring/flash layers.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]

        notificationRingOverlayView.wantsLayer = true
        notificationRingOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        notificationRingOverlayView.layer?.masksToBounds = false
        notificationRingOverlayView.autoresizingMask = [.width, .height]
        notificationRingLayer.fillColor = NSColor.clear.cgColor
        notificationRingLayer.lineJoin = .round
        notificationRingLayer.lineCap = .round
        notificationRingLayer.shadowOffset = .zero
        notificationRingLayer.opacity = 0
        notificationRingOverlayView.layer?.addSublayer(notificationRingLayer)
        notificationRingOverlayView.isHidden = true
        notificationRingOverlayView.frame = bounds
        addSubview(notificationRingOverlayView)

        flashOverlayView.wantsLayer = true
        flashOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        flashOverlayView.layer?.masksToBounds = false
        flashOverlayView.autoresizingMask = [.width, .height]
        flashLayer.fillColor = NSColor.clear.cgColor
        flashLayer.lineJoin = .round
        flashLayer.lineCap = .round
        flashLayer.shadowOffset = .zero
        flashLayer.opacity = 0
        flashOverlayView.layer?.addSublayer(flashLayer)
        flashOverlayView.frame = bounds
        addSubview(flashOverlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var acceptsFirstResponder: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - TerminalPaneChromeHosting

    public func configureNotificationRing(presentation: TerminalPaneRingPresentation) {
        notificationRingPresentation = presentation
        let color = presentation.strokeColor.cgColor
        notificationRingLayer.strokeColor = color
        notificationRingLayer.lineWidth = presentation.lineWidth
        notificationRingLayer.shadowColor = color
        notificationRingLayer.shadowOpacity = Float(presentation.glowOpacity)
        notificationRingLayer.shadowRadius = presentation.glowRadius
    }

    public func configureFlash(presentation: TerminalPaneRingPresentation) {
        lastFlashPresentation = presentation
    }

    public func setNotificationRing(visible: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setNotificationRing(visible: visible)
            }
            return
        }

        let targetHidden = !visible
        let targetOpacity: Float = visible ? 1 : 0
        guard notificationRingOverlayView.isHidden != targetHidden ||
                notificationRingLayer.opacity != targetOpacity else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notificationRingOverlayView.isHidden = targetHidden
        notificationRingLayer.opacity = targetOpacity
        CATransaction.commit()
    }

    public func triggerFlash(
        style: TerminalPaneFlashStyle,
        presentation: TerminalPaneRingPresentation,
        animation: TerminalPaneFlashAnimationSpec
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastFlashStyle = style
            self.lastFlashPresentation = presentation
            self.updateFlashPath(presentation: presentation)
            self.updateFlashAppearance(presentation: presentation)
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let keyframe = CAKeyframeAnimation(keyPath: "opacity")
            keyframe.values = animation.values.map { NSNumber(value: $0) }
            keyframe.keyTimes = animation.keyTimes.map { NSNumber(value: $0) }
            keyframe.duration = animation.duration
            keyframe.timingFunctions = animation.curves.map { curve in
                switch curve {
                case .easeIn:
                    return CAMediaTimingFunction(name: .easeIn)
                case .easeOut:
                    return CAMediaTimingFunction(name: .easeOut)
                }
            }
            self.flashLayer.add(keyframe, forKey: "cmux.flash")
        }
    }

    public func layoutPaneChrome(bounds: CGRect) {
        setFrameIfNeeded(notificationRingOverlayView, to: bounds)
        setFrameIfNeeded(flashOverlayView, to: bounds)
        updateNotificationRingPath()
        updateFlashPath(presentation: lastFlashPresentation)
        updateFlashAppearance(presentation: lastFlashPresentation)
    }

    // MARK: - Geometry

    private func updateNotificationRingPath() {
        updateOverlayRingPath(
            layer: notificationRingLayer,
            bounds: notificationRingOverlayView.bounds,
            inset: notificationRingPresentation.inset,
            radius: notificationRingPresentation.cornerRadius
        )
    }

    private func updateFlashPath(presentation: TerminalPaneRingPresentation) {
        updateOverlayRingPath(
            layer: flashLayer,
            bounds: flashOverlayView.bounds,
            inset: presentation.inset,
            radius: presentation.cornerRadius
        )
    }

    private func updateFlashAppearance(presentation: TerminalPaneRingPresentation) {
        let strokeColor = presentation.strokeColor.cgColor
        flashLayer.strokeColor = strokeColor
        flashLayer.shadowColor = strokeColor
        flashLayer.shadowOpacity = Float(presentation.glowOpacity)
        flashLayer.shadowRadius = presentation.glowRadius
    }

    private func updateOverlayRingPath(
        layer: CAShapeLayer,
        bounds: CGRect,
        inset: CGFloat,
        radius: CGFloat
    ) {
        layer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            layer.path = nil
            return
        }
        let rect = bounds.insetBy(dx: inset, dy: inset)
        layer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    @discardableResult
    private func setFrameIfNeeded(_ view: NSView, to frame: CGRect) -> Bool {
        guard !Self.rectApproximatelyEqual(view.frame, frame) else { return false }
        view.frame = frame
        return true
    }

    private static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        epsilon: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
        abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
        abs(lhs.size.width - rhs.size.width) <= epsilon &&
        abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    // MARK: - Debug

    /// The current notification-ring visibility/opacity, for debug probes.
    public var notificationRingDebugState: (isHidden: Bool, opacity: Float) {
        (notificationRingOverlayView.isHidden, notificationRingLayer.opacity)
    }
}

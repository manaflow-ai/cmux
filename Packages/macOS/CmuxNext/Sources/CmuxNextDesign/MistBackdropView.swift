public import AppKit
/// A non-interactive AppKit layer that paints a ``MistGradient`` scrim.
///
/// The owner inserts this view above its artwork and below its local content
/// cards. It deliberately does not host an image or intercept clicks, so the
/// existing window material remains the owner of artwork loading and hit
/// testing.
@MainActor
public final class MistBackdropView: NSView {
    /// The plan currently rendered by the view.
    public private(set) var plan: MistBackdropPlan?
    /// The Core Animation gradient used for the scrim.
    public let gradientLayer = CAGradientLayer()

    /// Creates an empty scrim view.
    ///
    /// - Parameters:
    ///   - frameRect: The initial frame.
    ///   - plan: An optional plan to render immediately.
    public init(frame frameRect: NSRect, plan: MistBackdropPlan? = nil) {
        self.plan = plan
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(gradientLayer)
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.isOpaque = false
        if let plan { apply(plan) }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Applies a plan without changing the view's frame or interaction.
    public func apply(_ plan: MistBackdropPlan) {
        self.plan = plan
        gradientLayer.colors = plan.gradient.stops.map(\.color.cgColor)
        gradientLayer.locations = plan.gradient.stops.map { NSNumber(value: $0.location) }
        gradientLayer.frame = bounds
    }

    override public func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }

    /// The scrim is decoration only; content cards receive all events.
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
}

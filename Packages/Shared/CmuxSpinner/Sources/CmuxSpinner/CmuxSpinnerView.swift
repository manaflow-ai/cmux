#if canImport(UIKit)
public import UIKit

/// The spinner as a UIKit view, in place of `UIActivityIndicatorView`: the arc in the view's
/// `tintColor` (secondary label ink unless set), turning while it is in a window and animating,
/// still under Reduce Motion. VoiceOver reads it as loading.
public final class CmuxSpinnerView: UIView {
    private let spinnerLayer = CmuxSpinnerLayer()

    /// Whether it turns (`startAnimating()` / `stopAnimating()`).
    public private(set) var isAnimating = false

    /// Hides the view while it is stopped, as `UIActivityIndicatorView` does.
    public var hidesWhenStopped = true {
        didSet { if !isAnimating { isHidden = hidesWhenStopped } }
    }

    /// Whether Reduce Motion holds the arc still: nil reads the system setting each time the spinner
    /// starts, stops or moves to a window; a host that tracks the setting (SwiftUI's
    /// `accessibilityReduceMotion`) passes it, so a change applies at once.
    public var reducesMotion: Bool? {
        didSet { if reducesMotion != oldValue { update() } }
    }

    /// The spinner's side, for its intrinsic size.
    public var side: CGFloat {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// - Parameter side: The spinner's side in points (20 is `UIActivityIndicatorView.medium`).
    public init(side: CGFloat = 20) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        isUserInteractionEnabled = false
        layer.addSublayer(spinnerLayer)
        tintColor = .secondaryLabel
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "spinner.loading", defaultValue: "Loading", bundle: .module)
        accessibilityTraits = .updatesFrequently
        isHidden = hidesWhenStopped
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: Self, _) in
            view.resolveTint()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    override public var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    /// The arc's ink (`tintColor`), named as `UIActivityIndicatorView` names it.
    public var color: UIColor {
        get { tintColor }
        set { tintColor = newValue }
    }

    /// Shows the spinner and turns it.
    public func startAnimating() {
        isAnimating = true
        isHidden = false
        update()
    }

    /// Stops the turn; hides the view when `hidesWhenStopped`.
    public func stopAnimating() {
        isAnimating = false
        if hidesWhenStopped { isHidden = true }
        update()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinnerLayer.frame = bounds
        CATransaction.commit()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        update()
    }

    override public func tintColorDidChange() {
        super.tintColorDidChange()
        resolveTint()
    }


    private func resolveTint() {
        spinnerLayer.tint = tintColor.resolvedColor(with: traitCollection).cgColor
    }

    private func update() {
        resolveTint()
        spinnerLayer.turn(isAnimating && window != nil && !(reducesMotion ?? UIAccessibility.isReduceMotionEnabled))
    }
}

#elseif canImport(AppKit)
public import AppKit

/// The spinner as an AppKit view, in place of `NSProgressIndicator`'s spinning style: the arc in
/// ``tint`` (secondary label ink unless set), turning while it is in a window and animating, still
/// under Reduce Motion. VoiceOver reads it as a busy indicator.
public final class CmuxSpinnerView: NSView {
    private let spinnerLayer = CmuxSpinnerLayer()

    /// Whether it turns (`startAnimation()` / `stopAnimation()`).
    public private(set) var isAnimating = false

    /// Hides the view while it is stopped, as `NSProgressIndicator.isDisplayedWhenStopped == false` does.
    public var hidesWhenStopped = true {
        didSet { if !isAnimating { isHidden = hidesWhenStopped } }
    }

    /// The arc's ink.
    public var tint: NSColor = .secondaryLabelColor {
        didSet { resolveTint() }
    }

    /// Whether Reduce Motion holds the arc still: nil reads the system setting each time the spinner
    /// starts, stops or moves to a window; a host that tracks the setting (SwiftUI's
    /// `accessibilityReduceMotion`) passes it, so a change applies at once.
    public var reducesMotion: Bool? {
        didSet { if reducesMotion != oldValue { update() } }
    }

    /// The spinner's side, for its intrinsic size.
    public var side: CGFloat {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// - Parameter side: The spinner's side in points (16 is a small `NSProgressIndicator`).
    public init(side: CGFloat = 16) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.addSublayer(spinnerLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.busyIndicator)
        setAccessibilityLabel(String(localized: "spinner.loading", defaultValue: "Loading", bundle: .module))
        isHidden = hidesWhenStopped
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    override public var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    /// Shows the spinner and turns it. `sender` is ignored, as `NSProgressIndicator`'s is.
    public func startAnimation(_ sender: Any? = nil) {
        isAnimating = true
        isHidden = false
        update()
    }

    /// Stops the turn; hides the view when `hidesWhenStopped`. `sender` is ignored.
    public func stopAnimation(_ sender: Any? = nil) {
        isAnimating = false
        if hidesWhenStopped { isHidden = true }
        update()
    }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinnerLayer.frame = bounds
        CATransaction.commit()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveTint()
    }


    private func resolveTint() {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = tint.cgColor }
        spinnerLayer.tint = color
    }

    private func update() {
        resolveTint()
        let still = reducesMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        spinnerLayer.turn(isAnimating && window != nil && !still)
    }
}
#endif

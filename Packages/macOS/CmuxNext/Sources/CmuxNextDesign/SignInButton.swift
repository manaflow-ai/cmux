public import AppKit

/// The one Sign In button: every place that says to sign in shows it beside the words, so the
/// person signs in with one click instead of looking for where to (Lawrence, msg 3790).
///
/// It draws as a dialog's default button (``CmuxDialogButtonLook`` `.default`: the theme's solid
/// accent fill and its on-accent ink, 4.5:1 in light and dark) at the density's control size
/// (``SignInButtonMetrics``). The caller passes what signing in means there (cmux, a harness, a
/// provider); the button only runs it.
///
/// ```swift
/// let button = SignInButton { services.signIn() }
/// stack.addArrangedSubview(button)
/// ```
@MainActor
public final class SignInButton: ClickableButton {
    /// The default title, "Sign In".
    public nonisolated static var defaultTitle: String { String(localized: "signIn.button", defaultValue: "Sign In", bundle: .module) }
    /// The identifier every Sign In button carries, so automation and tests find it.
    public static let identifier = NSUserInterfaceItemIdentifier("cmux.signIn.button")

    /// What a click runs.
    public var onSignIn: @MainActor () -> Void
    /// The title shown.
    public private(set) var signInTitle: String
    /// The density the button reads its sizes from; nil reads the app's (``DensityTokens/active``).
    public var density: DensityTokens? { didSet { refresh() } }
    private var isHovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: metrics.height)

    /// A button titled `title` that runs `onSignIn` when clicked.
    /// - Parameters:
    ///   - title: The title, "Sign In" by default; a place may name what it signs in to ("Sign In to Claude").
    ///   - onSignIn: Starts the sign-in this place needs.
    public init(title: String = SignInButton.defaultTitle, onSignIn: @escaping @MainActor () -> Void) {
        signInTitle = title
        self.onSignIn = onSignIn
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .exterior
        wantsLayer = true
        identifier = Self.identifier
        setAccessibilityLabel(title)
        target = self
        action = #selector(click)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightConstraint.isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sizes the button draws at now.
    public var metrics: SignInButtonMetrics {
        SignInButtonMetrics(density: density ?? DensityTokens.active, scale: Metrics.scale(1))
    }

    /// Shows a new title in place.
    public func retitle(_ title: String) {
        guard title != signInTitle else { return }
        signInTitle = title
        setAccessibilityLabel(title)
        refresh()
    }

    @objc private func click() { onSignIn() }

    public override var isEnabled: Bool { didSet { refresh() } }
    public override var isHighlighted: Bool { didSet { refresh() } }
    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }

    public override var intrinsicContentSize: NSSize {
        let metrics = metrics
        return NSSize(width: ceil(attributedTitle.size().width) + metrics.paddingX * 2, height: metrics.height)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovering = true }
    public override func mouseExited(with event: NSEvent) { isHovering = false }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    /// The colors the button draws in now: a dialog's default button in its theme scope.
    var look: CmuxDialogButtonLook {
        let state: CmuxDialogButtonLook.State = isHighlighted ? .pressed : isHovering ? .hover : .rest
        return performWithTheme {
            let tokens = ThemeContext.active ?? ThemeScope.app.tokens
            return CmuxDialogButtonLook(role: .default, tokens: tokens, state: state)
        }
    }

    private func refresh() {
        let look = look
        let metrics = metrics
        performWithTheme {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = look.fill.nsColor.cgColor
            layer?.cornerRadius = metrics.cornerRadius
            CATransaction.commit()
            alphaValue = isEnabled ? 1 : 0.45
            let font = NSFont.systemFont(ofSize: metrics.textSize, weight: .semibold)
            attributedTitle = NSAttributedString(string: signInTitle, attributes: [.foregroundColor: look.title.nsColor, .font: font])
        }
        if heightConstraint.constant != metrics.height { heightConstraint.constant = metrics.height }
        invalidateIntrinsicContentSize()
    }
}

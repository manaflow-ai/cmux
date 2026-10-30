public import AppKit

/// A toast: the message, the action button and a close button on the shared
/// neutral Liquid Glass (``FloatingGlassStyle/toast``: gray glass, a top-lit
/// rim, 9 pt continuous corners; user 2026-10-20, after Rex), opaque under
/// Reduce Transparency, with the popups' shadow. VoiceOver reads the message; the buttons are reachable with
/// VoiceOver and by click. The pointer on it holds it (`onHover`). A Details action
/// (``CmuxToast/Action/revealsDetails``) shows the whole message and its detail under it, in the
/// toast, and hides them again.
@MainActor
public final class CmuxToastView: NSView {
    public let toast: CmuxToast
    public private(set) var actionButton: CmuxToastButton?
    public let closeButton = CmuxToastButton(style: .close, title: CmuxToastStrings.dismiss, target: nil, action: nil)
    /// The message; its tooltip is the toast's `detail`.
    public private(set) var messageLabel: ChromeLabel?
    /// The toast's `detail` in full under the message, shown while Details is on; nil without a
    /// Details action or a detail.
    public private(set) var detailLabel: ChromeLabel?
    /// Whether Details is on: the whole message and ``detailLabel`` show.
    public private(set) var showsDetails = false
    var onAction: (() -> Void)?
    /// Details turned on or off: the toast's size changed, so its center sizes it again and
    /// restacks its window's toasts.
    var onResize: (() -> Void)?
    var onClose: (() -> Void)?
    /// The pointer came onto or left the toast, or the toast moved or went
    /// under a still pointer (`PointerHover`, cx-3wu5).
    var onHover: ((Bool) -> Void)?
    private var pointerHover: PointerHover?
    /// Whether the pointer is on the toast now (as of the last refresh).
    public var isHovered: Bool { pointerHover?.isHovering ?? false }

    private let reduceTransparency: ReduceTransparency

    /// Cmd-Z runs this Undo (`CmuxToast.Action.isUndo`): its tooltip shows the key. Only the
    /// window's newest undo toast takes the key (`CmuxToastStack.newestUndo`), so the center turns
    /// it off on the older ones.
    public var showsUndoKey = false {
        didSet { if showsUndoKey != oldValue { applyUndoKey() } }
    }

    /// `reduceTransparency` decides glass or the opaque surface (tests pass their own).
    public init(toast: CmuxToast, reduceTransparency: ReduceTransparency = .shared) {
        self.toast = toast
        self.reduceTransparency = reduceTransparency
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        showsUndoKey = toast.action?.isUndo == true
        applyUndoKey() // an initializer's own assignment runs no didSet
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(toast.message)
        setAccessibilityHelp(toast.detail)
        setAccessibilityIdentifier("cmux.toast.\(toast.id)")
        // Stable names for agents and UI tests (AccessibilityAudit wants one on every button).
        actionButton?.setAccessibilityIdentifier("cmux.toast.\(toast.id).action")
        closeButton.setAccessibilityIdentifier("cmux.toast.\(toast.id).close")
        pointerHover = PointerHover(self) { [weak self] hovering in self?.onHover?(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        let label = ChromeLabel(wrappingLabelWithString: toast.message)
        label.font = Typography.body
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 360
        // A wrapping label resists compression at only `.defaultLow`, the same as the stack's
        // hugging, so the toast's fitting size squeezed the message to 4 pt and drew only the
        // buttons. The message keeps its width (up to 360 pt, then it wraps).
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        performWithTheme { label.textColor = Palette.textPrimary }
        // The details stay out of the toast until Details shows them: the pointer on the message shows them.
        label.themedToolTip = toast.detail
        messageLabel = label
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        // Room around the message; the buttons' hover fills stop one step short of the edge,
        // so the toast reads as one surface with text in it.
        row.edgeInsets = NSEdgeInsets(top: Metrics.space4, left: Metrics.space5,
                                      bottom: Metrics.space4, right: Metrics.space4)
        row.translatesAutoresizingMaskIntoConstraints = false
        if let action = toast.action {
            let button = CmuxToastButton(style: .action, title: action.title, target: self, action: #selector(runAction))
            actionButton = button
            if action.isUndo { button.themedToolTip = action.title }
            row.addArrangedSubview(button)
            row.setCustomSpacing(Metrics.space5, after: label)
        }
        closeButton.target = self
        closeButton.action = #selector(close)
        row.addArrangedSubview(closeButton)

        let content = NSView()
        content.addSubview(row)
        if toast.action?.revealsDetails == true, let detail = toast.detail { addDetailLabel(detail, in: content, below: row) }
        // The shared neutral glass; the material follows this Mac (opaque under Reduce Transparency).
        let surface = OverlaySurfaceView(interactive: true, cornerRadius: Self.cornerRadius,
                                         reduceTransparency: reduceTransparency, tone: .neutralGlass(.toast))
        surface.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = surface.contentView.bounds
        surface.contentView.addSubview(content)
        addSubview(surface)
        castShadow()
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalTo: row.widthAnchor),
            // The stack's vertical edge insets do not hold its height (a toast's fitting height
            // was its tallest view's, so a message of two or three lines touched the glass's
            // top and bottom). The message keeps the room the buttons give a one-line message.
            label.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: Self.messageInset),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: Self.messageInset),
        ])
        collapsedHeight = heightAnchor.constraint(equalTo: row.heightAnchor)
        collapsedHeight?.isActive = true
    }

    /// The toast's height while Details is off: the row's.
    private var collapsedHeight: NSLayoutConstraint?
    /// The toast's height while Details is on: down to the detail, or the row's without one.
    private var expandedHeight: NSLayoutConstraint?

    /// The detail under the row, inset like the message, as wide as the toast and wrapping in it,
    /// selectable (a reason to copy into a bug), shown only while Details is on.
    private func addDetailLabel(_ detail: String, in content: NSView, below row: NSView) {
        let label = ChromeLabel(wrappingLabelWithString: detail)
        label.font = Typography.body
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        // It takes the toast's width, never sets it: a hidden view still lays out, and its text
        // on one line would widen the toast.
        label.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        label.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        performWithTheme { label.textColor = Palette.textSecondary }
        content.addSubview(label)
        detailLabel = label
        NSLayoutConstraint.activate([
            // The row's bottom inset is the gap above the detail.
            label.topAnchor.constraint(equalTo: row.bottomAnchor, constant: -Metrics.space2),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.space5),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.space5),
        ])
        expandedHeight = bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: Metrics.space4)
    }

    /// Details on or off: on, the message has no line limit and the detail shows under it (its
    /// tooltip goes, the text is there); off, the toast is as it was. The button stays lit while on.
    public func setShowsDetails(_ shows: Bool) {
        guard toast.action?.revealsDetails == true, shows != showsDetails else { return }
        showsDetails = shows
        // The message and the detail wrap at the toast's width now (the row sets it).
        let width = max(bounds.width, fittingSize.width)
        messageLabel?.maximumNumberOfLines = shows ? 0 : 3
        messageLabel?.themedToolTip = shows ? nil : toast.detail
        if let detailLabel {
            detailLabel.preferredMaxLayoutWidth = max(0, width - 2 * Metrics.space5)
            detailLabel.isHidden = !shows
            collapsedHeight?.isActive = !shows
            expandedHeight?.isActive = shows
        }
        actionButton?.isOn = shows
        actionButton?.setAccessibilityExpanded(shows)
        setAccessibilityHelp(shows ? nil : toast.detail)
        onResize?()
    }

    /// The least room above and below the message: about what a one-line message has beside
    /// the 22 pt buttons, so one-line toasts keep their height.
    static var messageInset: CGFloat { Metrics.space2 }

    /// The shared toast glass radius, never a capsule.
    static let cornerRadius = FloatingGlassStyle.toast.cornerRadius

    /// The popups' one subtle shadow, on this view's layer behind the surface
    /// (the surface clips to its corners, so it cannot cast its own).
    private func castShadow() {
        wantsLayer = true
        let elevation = PopupStyle.elevation2
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(elevation.alpha)
        layer?.shadowRadius = elevation.layerRadius
        layer?.shadowOffset = elevation.layerOffset()
    }

    public override func layout() {
        super.layout()
        // CoreGraphics refuses a corner wider than half the rect.
        let radius = min(Self.cornerRadius, min(bounds.width, bounds.height) / 2)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func applyUndoKey() {
        guard let button = actionButton, toast.action?.isUndo == true else { return }
        button.themedToolTipShortcut = showsUndoKey ? CmuxToastStrings.undoShortcut : nil
        // The tooltip's text is the title VoiceOver already reads; the help says only the key.
        button.setAccessibilityHelp(showsUndoKey ? CmuxToastStrings.undoShortcut : nil)
    }

    @objc private func runAction() {
        // Details shows the toast in full here; it never ends the toast.
        guard toast.action?.revealsDetails != true else { return setShowsDetails(!showsDetails) }
        onAction?()
    }
    @objc private func close() { onClose?() }
}

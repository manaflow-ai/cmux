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
    /// The toast's `detail` under the message, shown while Details is on: in plain words when it
    /// names a known error code (``CmuxToastDetailCopy``), else in full. Nil without a Details
    /// action or a detail.
    public private(set) var detailLabel: ChromeLabel?
    /// "Error code: fs.no_space" under the plain words, small and dimmed, selectable; its tooltip
    /// is the raw detail. Nil when the detail shows as it came.
    public private(set) var codeLabel: ChromeLabel?
    /// Holds ``detailLabel``: as tall as the detail up to ``detailCap(windowHeight:)``, then it
    /// scrolls, so a long reason never pushes the row with Details and close out of the window.
    public private(set) var detailScroll: NSScrollView?
    /// The detail's height cap, set from the toast's window when the details show and again
    /// whenever that window's size changes (``windowGeometryDidChange()``).
    private var detailCapConstraint: NSLayoutConstraint?
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
        // A toast wider than its row (Details on) gives the room to the message, so Details and
        // close stay at the trailing edge, on the title's line.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        performWithTheme { label.textColor = Palette.textPrimary }
        // The details stay out of the toast until Details shows them: the pointer on the message shows them.
        label.themedToolTip = toast.detail
        messageLabel = label
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        // Room past the row's own width goes to the message (no gravity gap after close). A
        // toast with Details off is exactly its row's width, so this changes nothing there.
        row.distribution = .fill
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
                                         reduceTransparency: reduceTransparency, tone: SurfaceRole.toast.tone)
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
        collapsed = [row.bottomAnchor.constraint(equalTo: content.bottomAnchor), heightAnchor.constraint(equalTo: row.heightAnchor)]
        NSLayoutConstraint.activate(collapsed)
    }

    /// The toast's height while Details is off: the row's, down to the content's bottom.
    private var collapsed: [NSLayoutConstraint] = []
    /// The toast's height while Details is on: the detail's bottom on the content's, the row
    /// free above it. Empty without a detail.
    private var expanded: [NSLayoutConstraint] = []

    /// The tallest the shown detail gets before it scrolls: 240 pt, or 40% of the window's height
    /// in a shorter window (no window: 240 pt).
    static func detailCap(windowHeight: CGFloat?) -> CGFloat {
        guard let windowHeight, windowHeight > 0 else { return 240 }
        return min(240, (windowHeight * 0.4).rounded(.down))
    }

    /// The most lines the message takes while Details shows (three while off); past them its
    /// tooltip has it in full.
    static let expandedMessageLines = 6

    /// The least width of a toast while Details shows, so the detail wraps as a paragraph instead
    /// of a narrow column under a short title.
    static let expandedMinWidth: CGFloat = 380

    /// The detail under the row, inset like the message, as wide as the toast and wrapping in it,
    /// selectable (a reason to copy into a bug), shown only while Details is on. It sits in a
    /// scroll view as tall as the detail up to ``detailCap(windowHeight:)``.
    private func addDetailLabel(_ detail: String, in content: NSView, below row: NSView) {
        let copy = CmuxToastDetailCopy.plain(detail)
        let label = ChromeLabel(wrappingLabelWithString: copy.text)
        label.font = Typography.body
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        label.focusRingType = .none
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        // It takes the toast's width, never sets it: a hidden view still lays out, and its text
        // on one line would widen the toast.
        label.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        label.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        performWithTheme { label.textColor = Palette.textSecondary }
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(label)
        var bottom = label.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        if let code = copy.code {
            let line = ChromeLabel(wrappingLabelWithString: CmuxToastDetailCopy.codeLine(code))
            line.font = Typography.caption
            line.maximumNumberOfLines = 0
            line.isSelectable = true
            line.focusRingType = .none
            line.isHidden = true
            line.translatesAutoresizingMaskIntoConstraints = false
            line.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
            line.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
            performWithTheme { line.textColor = Palette.textTertiary }
            // The raw reason, word for word, for a bug report.
            line.themedToolTip = detail
            document.addSubview(line)
            codeLabel = line
            bottom = line.bottomAnchor.constraint(equalTo: document.bottomAnchor)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Metrics.space2),
                line.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            ])
        }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        SystemScrollers.follow(scroll)
        scroll.documentView = document
        scroll.isHidden = true
        content.addSubview(scroll)
        detailLabel = label
        detailScroll = scroll
        // As tall as the detail (below required), never past the cap (required).
        let cap = scroll.heightAnchor.constraint(lessThanOrEqualToConstant: Self.detailCap(windowHeight: nil))
        let fit = scroll.heightAnchor.constraint(equalTo: document.heightAnchor)
        fit.priority = .defaultHigh
        detailCapConstraint = cap
        NSLayoutConstraint.activate([
            // The row's bottom inset is the gap above the detail: the title row, then the detail
            // as its own block.
            scroll.topAnchor.constraint(equalTo: row.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.space5),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.space5),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            label.topAnchor.constraint(equalTo: document.topAnchor),
            label.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bottom,
            cap, fit,
        ])
        expanded = [content.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: Metrics.space4),
                    widthAnchor.constraint(greaterThanOrEqualToConstant: Self.expandedMinWidth)]
    }

    /// Details on or off: on, the message has no line limit and the detail shows under it (its
    /// tooltip goes, the text is there); off, the toast is as it was. The button stays lit while on.
    public func setShowsDetails(_ shows: Bool) {
        guard toast.action?.revealsDetails == true, shows != showsDetails else { return }
        showsDetails = shows
        // Details while off, Hide Details while on: the same button, on the title's line.
        if let action = toast.action { actionButton?.setTitle(shows ? CmuxToastStrings.hideDetails : action.title) }
        // The message and the detail wrap at the toast's width now (the row sets it), never
        // narrower than an expanded toast.
        let width = max(bounds.width, fittingSize.width, shows ? Self.expandedMinWidth : 0)
        messageLabel?.maximumNumberOfLines = shows ? Self.expandedMessageLines : 3
        // Shown, the detail is there; a message past its lines keeps the whole of it in the tooltip.
        messageLabel?.themedToolTip = shows ? toast.message : toast.detail
        if let detailLabel {
            // Inside the scroll view, short of its scroller's width.
            detailLabel.preferredMaxLayoutWidth = max(0, width - 2 * Metrics.space5 - Metrics.space4)
            codeLabel?.preferredMaxLayoutWidth = detailLabel.preferredMaxLayoutWidth
            codeLabel?.isHidden = !shows
            detailLabel.isHidden = !shows
            detailScroll?.isHidden = !shows
            applyDetailCap()
            // Off before on, so the two sets never hold at once.
            NSLayoutConstraint.deactivate(shows ? collapsed : expanded)
            NSLayoutConstraint.activate(shows ? expanded : collapsed)
        }
        actionButton?.isOn = shows
        actionButton?.setAccessibilityExpanded(shows)
        setAccessibilityHelp(shows ? nil : toast.detail)
        onResize?()
    }

    /// The cap for the toast's window as it is now.
    private func applyDetailCap() {
        detailCapConstraint?.constant = Self.detailCap(windowHeight: window?.contentLayoutRect.height)
    }

    /// A window that grows or shrinks (a resize, full screen) after Details showed caps the detail
    /// again, and the center sizes and restacks the toast, so a shorter window never pushes the row
    /// with Details and close off screen. The window's overlay host calls it from its one observer
    /// of the window (``OverlayHandle/onWindowGeometryChange``, set by ``CmuxToastOverlayHost``).
    func windowGeometryDidChange() {
        let before = detailCapConstraint?.constant
        applyDetailCap()
        guard showsDetails, detailCapConstraint?.constant != before else { return }
        onResize?()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, detailScroll != nil else { return }
        applyDetailCap()
    }

    /// The least room above and below the message: about what a one-line message has beside
    /// the 22 pt buttons, so one-line toasts keep their height.
    static var messageInset: CGFloat { Metrics.space2 }

    /// The shared toast glass radius, never a capsule.
    static let cornerRadius = SurfaceRole.toast.cornerRadius ?? FloatingGlassStyle.toast.cornerRadius

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

/// The detail's document view: its text from the top.
private final class FlippedDocumentView: NSView {
    nonisolated override var isFlipped: Bool { true }
}

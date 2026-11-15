public import AppKit

/// A toast: the message, the action button and a close button on the toast role's glass
/// (``SurfaceRole/toast``, ``FloatingGlassStyle/toast``: Liquid Glass with the theme's tint and a
/// top-lit rim on macOS 26, the frosted blur before it, continuous corners; user 2026-10-20, after
/// Rex; the tint follows the theme since Leo 2026-11-07: "these toasts are still coloured
/// unthemed"), opaque under Reduce Transparency, with the popups' shadow. Native again since
/// Lawrence 2026-11-10 ("move toasts back to swift ... with proper liquid glass"); the web toast
/// page of #37289 is gone. VoiceOver reads the message; the buttons are reachable with
/// VoiceOver and by click. The pointer on it holds it (`onHover`). A Details action
/// (``CmuxToast/Action/revealsDetails``) shows the whole message and its detail under it, in the
/// toast, and hides them again.
@MainActor
public final class CmuxToastView: NSView {
    public let toast: CmuxToast
    public private(set) var actionButton: CmuxToastButton?
    /// Don't Show Again (Lawrence 2026-11-12): hides every toast of this kind for good
    /// (``CmuxToastCenter/personChoseNeverShow(serial:)``). Nil on a toast that does not offer it
    /// (``CmuxToast/offersNeverShow``: an Undo, one that waits for an answer).
    public private(set) var neverShowButton: CmuxToastButton?
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
    /// The action button was pressed. A Details button too: the center owns whether the details
    /// show (``CmuxToastCenter/personRanAction(serial:)``), and the host sets it back here
    /// (``setShowsDetails(_:)``).
    public var onAction: (() -> Void)?
    /// The prompt's second action was pressed (``CmuxToast/secondaryAction``).
    public var onSecondaryAction: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onNeverShow: (() -> Void)?
    /// The pointer came onto or left the toast, or the toast moved or went
    /// under a still pointer (`PointerHover`, cx-3wu5).
    public var onHover: ((Bool) -> Void)?
    /// The prompt's second action (Later, Show Crash Log), a quiet text button before the primary one.
    public private(set) var secondaryButton: CmuxToastButton?
    /// The leading icon of a style that shows one (``CmuxToastLook/showsIcon``).
    public private(set) var iconView: NSImageView?
    /// The SF Symbol the icon shows: an Undo's arrow, else the tone's (``CmuxToastTone/symbolName``).
    public var iconSymbol: String {
        toast.action?.isUndo == true ? "arrow.uturn.backward.circle.fill" : toast.tone.symbolName
    }
    /// The ring that empties over the toast's time (``CmuxToastLook/showsCountdown``); nil on a toast that waits.
    public private(set) var countdownRing: CmuxToastCountdownRing?
    /// The detail as a second line (``CmuxToastLook/showsDetailLine``).
    public private(set) var detailLine: ChromeLabel?
    /// The style this toast draws in.
    public let style: CmuxToastStyle
    /// What ``style`` draws.
    public var look: CmuxToastLook { style.look }
    /// The surface's corner radius now: half the height for a capsule, else the toast role's.
    public var cornerRadius: CGFloat {
        look.shape == .capsule ? bounds.height / 2 : Self.cornerRadius
    }
    private var pointerHover: PointerHover?
    /// Whether the pointer is on the toast now (as of the last refresh).
    public var isHovered: Bool { pointerHover?.isHovering ?? false }

    private let reduceTransparency: ReduceTransparency
    /// The look this toast was built with (Debug Settings > Toasts, else the defaults).
    public let tuning: CmuxToastTuning

    /// Cmd-Z runs this Undo (`CmuxToast.Action.isUndo`): its tooltip shows the key. Only the
    /// window's newest undo toast takes the key (`CmuxToastStack.newestUndo`), so the center turns
    /// it off on the older ones.
    public var showsUndoKey = false {
        didSet { if showsUndoKey != oldValue { applyUndoKey() } }
    }

    /// `reduceTransparency` decides glass or the opaque surface (tests pass their own); `tuning` is the
    /// padding, message width and glass (the center's ``CmuxToastCenter/tuning``; the defaults otherwise).
    public init(toast: CmuxToast, reduceTransparency: ReduceTransparency = .shared, tuning: CmuxToastTuning = CmuxToastTuning(),
                style: CmuxToastStyle? = nil) {
        self.toast = toast
        let style = style ?? toast.style ?? .standard
        self.style = style
        // A solid toast draws on the opaque surface, as under Reduce Transparency, and fits its text to it.
        // glass-opaque-allow: the Solid style is a look the person picks in the Toast Playground on purpose.
        self.reduceTransparency = style.look.solid ? .alwaysOpaque : reduceTransparency
        self.tuning = tuning
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(toast.message)
        setAccessibilityHelp(toast.detail)
        setAccessibilityIdentifier("cmux.toast.\(toast.id)")
        // Stable names for agents and UI tests (AccessibilityAudit wants one on every button).
        actionButton?.setAccessibilityIdentifier("cmux.toast.\(toast.id).action")
        closeButton.setAccessibilityIdentifier("cmux.toast.\(toast.id).close")
        neverShowButton?.setAccessibilityIdentifier("cmux.toast.\(toast.id).neverShow")
        secondaryButton?.setAccessibilityIdentifier("cmux.toast.\(toast.id).secondary")
        pointerHover = PointerHover(self) { [weak self] hovering in self?.pointerChanged(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        let look = self.look
        let label = ThemedLabel(wrappingLabelWithString: toast.message)
        let twoLines = look.showsDetailLine && toast.detail != nil && toast.action?.revealsDetails != true
        label.font = look.compact ? Typography.caption : twoLines ? Typography.bodyEmphasized : Typography.body
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = tuning.messageWidth
        // A wrapping label resists compression at only `.defaultLow`, the same as the stack's
        // hugging, so the toast's fitting size squeezed the message to 4 pt and drew only the
        // buttons. The message keeps its width (up to 360 pt, then it wraps).
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        // A toast wider than its row (Details on) gives the room to the message, so Details and
        // close stay at the trailing edge, on the title's line.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Fitted to the ground it draws on (the glass, or the opaque surface under Reduce Transparency) in
        // the scope it draws in, again on every theme change (GlassTextEveryThemeTests).
        let ground = self.reduceTransparency
        label.themeColor = { Palette.toastText(.primary, reduceTransparency: ground) }
        // The details stay out of the toast until Details shows them: the pointer on the message shows them.
        label.themedToolTip = twoLines ? nil : toast.detail
        messageLabel = label
        // The message, with the detail under it in a style that shows it as a second line.
        var text: NSView = label
        if twoLines, let detail = toast.detail {
            let line = ThemedLabel(wrappingLabelWithString: detail)
            line.font = Typography.caption
            line.maximumNumberOfLines = 2
            line.preferredMaxLayoutWidth = tuning.messageWidth
            line.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            line.themeColor = { Palette.toastText(.secondary, reduceTransparency: ground) }
            detailLine = line
            let block = NSStackView(views: [label, line])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 2
            block.setContentHuggingPriority(.defaultLow, for: .horizontal)
            text = block
        }
        let row = NSStackView(views: [text])
        row.orientation = .horizontal
        row.alignment = .centerY
        // Room past the row's own width goes to the message (no gravity gap after close). A
        // toast with Details off is exactly its row's width, so this changes nothing there.
        row.distribution = .fill
        row.spacing = Metrics.scale(tuning.buttonSpacing)
        // Room around the message; the buttons' hover fills stop one step short of the edge,
        // so the toast reads as one surface with text in it.
        // The tuned points follow the interface scale, as the grid steps they replace did.
        // A compact toast takes two thirds of the padding.
        let pad: (CGFloat) -> CGFloat = { Metrics.scale(look.compact ? ($0 * 2 / 3).rounded() : $0) }
        row.edgeInsets = NSEdgeInsets(top: pad(tuning.verticalPadding), left: pad(tuning.horizontalPadding) + (look.accentBar ? Self.accentBarWidth : 0),
                                      bottom: pad(tuning.verticalPadding), right: pad(tuning.trailingPadding))
        if look.showsIcon {
            let icon = ThemedImageView()
            let tone = toast.tone
            icon.themeTint = { tone.color }
            icon.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: look.compact ? 13 : 16, weight: TypeScale.regular))
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            icon.setAccessibilityElement(false)
            iconView = icon
            row.insertArrangedSubview(icon, at: 0)
            row.setCustomSpacing(Metrics.space4, after: icon)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        if let secondary = toast.secondaryAction {
            let button = CmuxToastButton(style: .quiet, title: secondary.title, target: self, action: #selector(runSecondaryAction))
            secondaryButton = button
            row.addArrangedSubview(button)
            row.setCustomSpacing(Metrics.space5, after: text)
        }
        if let action = toast.action {
            let button = CmuxToastButton(style: look.fillsAction ? .filled : .action, title: action.title, target: self, action: #selector(runAction))
            actionButton = button
            if action.isUndo { button.themedToolTip = action.title }
            row.addArrangedSubview(button)
            if toast.secondaryAction == nil { row.setCustomSpacing(Metrics.space5, after: text) }
        }
        if toast.offersNeverShow {
            let button = CmuxToastButton(style: .quiet, title: CmuxToastStrings.dontShowAgain, target: self, action: #selector(neverShow))
            neverShowButton = button
            row.addArrangedSubview(button)
            if toast.action == nil { row.setCustomSpacing(Metrics.space5, after: text) }
        }
        closeButton.target = self
        closeButton.action = #selector(close)
        row.addArrangedSubview(closeButton)
        // Hidden until the pointer is on the toast; still in the row, so VoiceOver and Full Keyboard Access reach it.
        if look.closeOnHover { closeButton.alphaValue = 0 }

        let content = NSView()
        content.addSubview(row)
        if toast.action?.revealsDetails == true, let detail = toast.detail { addDetailLabel(detail, in: content, below: row) }
        // The toast role's glass; the material follows this Mac (opaque under Reduce Transparency).
        let surface = OverlaySurfaceView(material: look.solid ? .opaque : nil, interactive: true, cornerRadius: Self.cornerRadius,
                                         reduceTransparency: reduceTransparency, tone: SurfaceRole.toast.tone,
                                         glassVariant: (look.glass ?? tuning.glass).variant)
        // The overlay panel is a clear window of its own: before macOS 26 the blur samples what is
        // behind it (the window's content). Liquid Glass and the opaque surface ignore this.
        surface.samplesBehindWindow = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        self.surface = surface
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = surface.contentView.bounds
        surface.contentView.addSubview(content)
        addSubview(surface)
        if look.accentBar { addAccentBar(in: content) }
        if look.showsCountdown, toast.duration != CmuxToast.untilClosed { addCountdownRing(in: content) }
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
            text.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: Self.messageInset),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: Self.messageInset),
        ])
        collapsed = [row.bottomAnchor.constraint(equalTo: content.bottomAnchor), heightAnchor.constraint(equalTo: row.heightAnchor)]
        NSLayoutConstraint.activate(collapsed)
    }

    /// The glass the toast draws on: this Mac's material in the toast role's tone.
    public private(set) var surface: OverlaySurfaceView?

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
        let label = ThemedLabel(wrappingLabelWithString: copy.text)
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
        let ground = self.reduceTransparency
        label.themeColor = { Palette.toastText(.secondary, reduceTransparency: ground) }
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(label)
        var bottom = label.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        if let code = copy.code {
            let line = ThemedLabel(wrappingLabelWithString: CmuxToastDetailCopy.codeLine(code))
            line.font = Typography.caption
            line.maximumNumberOfLines = 0
            line.isSelectable = true
            line.focusRingType = .none
            line.isHidden = true
            line.translatesAutoresizingMaskIntoConstraints = false
            line.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
            line.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
            line.themeColor = { Palette.toastText(.tertiary, reduceTransparency: ground) }
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
    /// tooltip goes, the text is there); off, the toast is as it was. The button reads Hide Details
    /// with an up chevron while on, a quiet link, never a lit chip.
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
    }

    /// The cap for the toast's window as it is now.
    private func applyDetailCap() {
        detailCapConstraint?.constant = Self.detailCap(windowHeight: window?.contentLayoutRect.height)
    }

    /// A window that grows or shrinks (a resize, full screen) after Details showed caps the detail
    /// again, so a shorter window never pushes the row with Details and close off screen. The
    /// toast host calls it from the overlay's one observer of the window
    /// (``OverlayHandle/onWindowGeometryChange``), then sizes and restacks the window's toasts.
    func windowGeometryDidChange() {
        applyDetailCap()
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
    static var cornerRadius: CGFloat { SurfaceRole.toast.cornerRadius }

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
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        if surface?.cornerRadius != radius { surface?.cornerRadius = radius }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// The accent bar's width (``CmuxToastLook/accentBar``).
    static let accentBarWidth: CGFloat = 4

    /// A bar in the tone's color along the leading edge, under the glass's rounded corner.
    private func addAccentBar(in content: NSView) {
        let bar = ThemeChangeView()
        bar.wantsLayer = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        let tone = toast.tone
        bar.onThemeChange = { [weak bar] in
            guard let bar else { return }
            bar.layer?.backgroundColor = bar.performWithTheme { tone.color.cgColor }
        }
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: Self.accentBarWidth),
        ])
    }

    /// The countdown ring, centered on the close button.
    private func addCountdownRing(in content: NSView) {
        let ring = CmuxToastCountdownRing(duration: tuning.shownDuration(of: toast))
        content.addSubview(ring)
        NSLayoutConstraint.activate([
            ring.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
        ])
        countdownRing = ring
    }

    /// The pointer came onto or left the toast: a hover-only close button shows, the countdown holds
    /// full (the toast's time starts again in full when the pointer leaves), and the host hears it.
    private func pointerChanged(_ hovering: Bool) {
        if look.closeOnHover {
            let close = closeButton
            Motion.overlays.animate(hovering ? .fadeIn : .fadeOut, in: self) { close.animator().alphaValue = hovering ? 1 : 0 }
        }
        countdownRing?.hold(hovering)
        onHover?(hovering)
    }

    private func applyUndoKey() {
        guard let button = actionButton, toast.action?.isUndo == true else { return }
        button.themedToolTipShortcut = showsUndoKey ? CmuxToastStrings.undoShortcut : nil
        // The tooltip's text is the title VoiceOver already reads; the help says only the key.
        button.setAccessibilityHelp(showsUndoKey ? CmuxToastStrings.undoShortcut : nil)
    }

    @objc private func runAction() { onAction?() }
    @objc private func runSecondaryAction() { onSecondaryAction?() }
    @objc private func close() { onClose?() }
    @objc private func neverShow() { onNeverShow?() }
}

/// The detail's document view: its text from the top.
private final class FlippedDocumentView: NSView {
    nonisolated override var isFlipped: Bool { true }
}

public import AppKit

/// A toast's action (Undo, Reopen, Details), Don't Show Again or close button: a clear text button
/// in the primary text color (Don't Show Again in the secondary one, lit under the pointer: it is the
/// quiet choice), or a small xmark, on the toast's own surface,
/// with the shared hover fill only under the pointer. No second capsule, no
/// accent color.
@MainActor
public final class CmuxToastButton: ClickableButton {
    public enum Style {
        case action
        /// Don't Show Again: a text button in the secondary text color, regular weight.
        case quiet
        case close
        /// A primary action filled with the theme's accent (``CmuxToastStyle/filledAction``).
        case filled
        /// A primary action filled with the toast's own ink, the title in the glass's color: a small
        /// dark Undo on light glass, a light one on dark (``CmuxToastStyle/v2``).
        case ink
    }

    /// Whether the button is the accent-filled primary action.
    public var isFilled: Bool { style == .filled }

    /// Horizontal padding of the action title inside its hover fill.
    static let titlePadding: CGFloat = 6
    /// Every toast button's height, and close's side: one height, so each sits the toast's padding from its top
    /// and bottom and close the same padding from its trailing edge (``CmuxToastView/geometry``).
    public static let height: CGFloat = 22
    /// The hover and pressed shape's corner: the toast's concentric child corner
    /// (``ConcentricContainer/childRadius``), at most half the button's height. The toast sets it.
    public var concentricRadius: CGFloat = Metrics.buttonCornerRadius {
        didSet { if concentricRadius != oldValue { needsLayout = true; applyStyle() } }
    }
    /// ``concentricRadius`` on this button's size now.
    private var fittedRadius: CGFloat {
        let side = min(bounds.width, bounds.height)
        return side > 0 ? min(concentricRadius, side / 2) : concentricRadius
    }
    let style: Style
    private var plainTitle: String
    /// A disclosure that is open (a toast's Details while they show): a quiet text link, the
    /// title in the secondary text color with an up chevron after it, never a filled chip. Only
    /// the pointer lights it, like any toast button (Leo, 2026-11-01: "the details toast doesnt
    /// look very good").
    public var isOn = false {
        didSet {
            guard isOn != oldValue, style == .action else { return }
            image = isOn ? Self.disclosureChevron : nil
            imagePosition = isOn ? .imageTrailing : .noImage
            applyStyle()
            invalidateIntrinsicContentSize()
        }
    }
    /// The open disclosure's chevron: the close button's size and weight, so the two read as a pair.
    static let disclosureChevron = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
    /// Room between an open disclosure's title and its chevron.
    static let chevronGap: CGFloat = 4
    /// A quiet button that rests on a faint fill of the toast's text color, so it reads as a button and not as
    /// more of the message (``CmuxToastButtonRow/chips``); the pointer still lights it with the hover fill.
    public var restsOnFill = false {
        didSet {
            guard restsOnFill != oldValue else { return }
            if !restsOnFill { hover.refresh(animated: false) }  // back to the hover's own fill (none at rest)
            applyStyle()
        }
    }
    /// The fill the button shows now (tests): nil when it shows none.
    var shownFill: NSColor? { ChromeHover.fillColor(hover.state) }
    private lazy var hover = ChromeHover(self, cornerRadius: Metrics.buttonCornerRadius, behindContent: true)

    init(style: Style, title: String, target: AnyObject?, action: Selector?) {
        self.style = style
        plainTitle = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        self.target = target
        self.action = action
        setAccessibilityLabel(title)
        switch style {
        case .action, .quiet, .filled, .ink:
            heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        case .close:
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            image = NSImage(systemSymbolName: "xmark", accessibilityDescription: title)?.withSymbolConfiguration(config)
            imagePosition = .imageOnly
            widthAnchor.constraint(equalToConstant: Self.height).isActive = true
            heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        hover.refresh(animated: false)
        // Hover follows the pointer and the toast's slot (cx-3wu5).
        hover.followPointer(onChange: { [weak self] in self?.applyStyle() })
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize {
        guard style != .close else { return NSSize(width: Self.height, height: Self.height) }
        let text = attributedTitle.size()
        let chevron = image.map { ceil($0.size.width) + Self.chevronGap } ?? 0
        // Never narrower than the cell needs to draw the whole title: the cell's own insets clipped a title sized
        // to its text alone to "Restart cmux-tui…" (Leo, 2026-11-03).
        let drawn = cell.map { ceil($0.cellSize.width) } ?? 0
        return NSSize(width: max(ceil(text.width) + chevron + Self.titlePadding * (style == .filled || style == .ink ? 3 : 2), drawn), height: Self.height)
    }

    /// The frame is the alignment rect: the toast's row centres the frames, so Details and close sit on one
    /// centre line. AppKit's own insets for a borderless button put them a
    /// point apart.
    nonisolated public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func applyStyle() {
        performWithTheme {
            switch style {
            case .action:
                // Open, it is a quiet link (secondary text, lit to primary under the pointer).
                let color = Palette.toastText(!isOn || hover.state.hovering || hover.state.pressed ? .primary : .secondary)
                attributedTitle = NSAttributedString(string: plainTitle, attributes: [
                    .font: Typography.bodyEmphasized,
                    .foregroundColor: color,
                ])
                contentTintColor = color
            case .quiet:
                let color = Palette.toastText(hover.state.hovering || hover.state.pressed ? .primary : .secondary)
                attributedTitle = NSAttributedString(string: plainTitle, attributes: [.font: Typography.body, .foregroundColor: color])
                contentTintColor = color
                // The hover fill lives in this layer's background (ChromeHover behindContent): the resting fill
                // goes there only while the pointer is off, and nothing here clears the hover's own fill.
                if restsOnFill, !hover.state.hovering, !hover.state.pressed {
                    wantsLayer = true
                    layer?.cornerRadius = fittedRadius
                    layer?.backgroundColor = Palette.toastText(.primary).withAlphaComponent(0.08).cgColor
                }
            case .close:
                contentTintColor = Palette.toastText(hover.state.hovering || hover.state.pressed ? .primary : .secondary)
            case .filled:
                // The accent fill, a little deeper under the pointer and pressed; the title on it in the
                // theme's on-accent ink.
                wantsLayer = true
                layer?.cornerRadius = fittedRadius
                let fill = Palette.accentFill
                let lit = hover.state.pressed ? fill.blended(withFraction: 0.2, of: .black) : hover.state.hovering ? fill.blended(withFraction: 0.1, of: .black) : fill
                layer?.backgroundColor = (lit ?? fill).cgColor
                attributedTitle = NSAttributedString(string: plainTitle, attributes: [
                    .font: Typography.bodyEmphasized,
                    .foregroundColor: Palette.onAccent,
                ])
                contentTintColor = Palette.onAccent
            case .ink:
                // The toast's primary text color as the fill, a little lighter under the pointer and pressed (the
                // fill is the only thing a held button changes); the title in the inverse ink.
                wantsLayer = true
                layer?.cornerRadius = fittedRadius
                let fill = Palette.toastText(.primary)
                let lit = hover.state.pressed ? fill.withAlphaComponent(0.72) : hover.state.hovering ? fill.withAlphaComponent(0.86) : fill
                layer?.backgroundColor = lit.cgColor
                let title = Palette.toastInkTitle()
                attributedTitle = NSAttributedString(string: plainTitle, attributes: [.font: Typography.bodyEmphasized, .foregroundColor: title])
                contentTintColor = title
            }
        }
    }

    /// Shows `title` (Details while off, Hide Details while on): VoiceOver reads it and the button
    /// sizes to it.
    func setTitle(_ title: String) {
        guard style == .action || style == .filled || style == .ink, title != plainTitle else { return }
        plainTitle = title
        setAccessibilityLabel(title)
        applyStyle()
        invalidateIntrinsicContentSize()
    }

    /// Lights or unlights the button as the pointer would (tests).
    func showHover(_ hovering: Bool) { changeHover { $0.hovering = hovering } }

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
        var state = hover.state
        change(&state)
        hover.state = state
        applyStyle()
    }

    public override func layout() {
        super.layout()
        hover.cornerRadius = fittedRadius
        if restsOnFill { layer?.cornerRadius = fittedRadius }
        hover.layout()
    }

    public override func mouseDown(with event: NSEvent) {
        changeHover { $0.pressed = true }
        super.mouseDown(with: event)
        changeHover { $0.pressed = false }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hover.refresh(animated: false)
        applyStyle()
    }
}

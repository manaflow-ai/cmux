import AppKit
import CmuxNextDesign

/// A small glass card at the bottom of the page that offers to bring the
/// person's cookies over from their other browsers: up to three browser
/// icons, one title, one line of detail, then Don't Show Again (a quiet
/// link), Not Now and Import Cookies. It never takes focus and every answer
/// closes it. It is the shared neutral glass of dialogs and prompt bars
/// (`FloatingGlassStyle.dialog`: its veil, soft top-lit rim and radius) with
/// the popups' shadow, never the theme-tinted glass with a veil of its own,
/// whose square-clipped edge read as a dark, heavy outline over bright pages
/// (Lawrence 2026-10-31: "border here looks bad"). Its material is the
/// frosted blur of what is behind its window, never Liquid Glass, whose lens
/// has nothing to bend in the clear overlay window and drew a dark 1 px
/// outline (`prefersBlurToLiquidGlass`). Under Reduce Transparency it is
/// opaque (`OverlaySurfaceView`).
final class BrowserCookieImportCard: NSView {
    static let maximumIcons = 3
    var onChoice: ((BrowserCookieImportChoice) -> Void)?
    /// Set while the close animation runs; a new offer then gets a new card.
    var isDismissing = false
    private(set) var offer: BrowserCookieImportOffer
    private let icons = NSStackView()
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let detailLabel = ChromeLabel(wrappingLabelWithString: "")
    let neverButton = CookieCardLinkButton()
    private(set) lazy var notNowButton = ChromeTextButton(title: offer.notNowTitle, prominent: false, action: #selector(notNow), target: self)
    private(set) lazy var importButton = ChromeTextButton(title: offer.importTitle, prominent: true, action: #selector(importCookies), target: self)
    private let density = DensityBinding()
    /// The card's material: glass, or opaque under Reduce Transparency.
    private(set) var glass: OverlaySurfaceView?

    init(offer: BrowserCookieImportOffer) {
        self.offer = offer
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = offer.title
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.stringValue = offer.detail
        detailLabel.maximumNumberOfLines = 2
        detailLabel.truncatesLastVisibleLine = true
        detailLabel.isSelectable = false
        neverButton.configure(title: offer.neverTitle ?? "", target: self, action: #selector(never))
        neverButton.isHidden = offer.neverTitle == nil
        icons.orientation = .horizontal
        icons.setHuggingPriority(.required, for: .horizontal)
        for image in offer.icons.prefix(Self.maximumIcons) { icons.addArrangedSubview(Self.iconView(image)) }
        icons.isHidden = icons.arrangedSubviews.isEmpty

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [icons, text])
        header.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [neverButton, spacer, notNowButton, importButton])
        buttons.alignment = .centerY
        let stack = NSStackView(views: [header, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: Self.style.cornerRadius, tone: .neutralGlass(Self.style))
        // It floats on the overlay host, a clear window over the page's own window: the blur
        // samples the page behind it; Liquid Glass there drew a dark 1 px outline.
        glass.samplesBehindWindow = true
        glass.prefersBlurToLiquidGlass = true
        addSubview(glass)
        castShadow()
        self.glass = glass
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: buttons.widthAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            density.bind(widthAnchor.constraint(lessThanOrEqualToConstant: 0)) { BrowserMetrics.promptMaxWidth },
            // Preferred width: a pane narrower than it narrows the card.
            density.bind(widthAnchor.constraint(equalToConstant: 0).prioritized(.init(450))) { BrowserMetrics.promptMaxWidth },
        ])
        density.update { [weak self] in
            guard let self else { return }
            let padding = BrowserMetrics.overlayPadding
            titleLabel.font = BrowserMetrics.emphasizedFont
            detailLabel.font = BrowserMetrics.captionFont
            detailLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth - padding * 2 - Self.iconsWidth - BrowserMetrics.itemSpacing
            neverButton.textFont = BrowserMetrics.captionFont
            icons.spacing = -Metrics.space1
            text.spacing = Metrics.space1 / 2
            header.spacing = BrowserMetrics.itemSpacing
            buttons.spacing = BrowserMetrics.buttonSpacing * 2
            stack.spacing = padding * 3 / 4
            stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding * 3 / 4, right: padding * 3 / 4)
        }
        density.start()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(offer.title)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The shared prompt glass.
    static let style = FloatingGlassStyle.dialog

    /// The popups' one subtle shadow, on this view's layer behind the glass
    /// (the glass clips to its corners, so it cannot cast its own).
    private func castShadow() {
        wantsLayer = true
        let elevation = PopupStyle.elevation2
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(elevation.alpha)
        layer?.shadowRadius = elevation.layerRadius
        layer?.shadowOffset = elevation.layerOffset()
    }

    override func layout() {
        super.layout()
        // CoreGraphics refuses a corner wider than half the rect.
        let radius = min(Self.style.cornerRadius, min(bounds.width, bounds.height) / 2)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static var iconSize: CGFloat { Metrics.iconSize + Metrics.space2 }
    private static var iconsWidth: CGFloat { iconSize * CGFloat(maximumIcons) - Metrics.space1 * CGFloat(maximumIcons - 1) }

    private static func iconView(_ image: NSImage) -> NSImageView {
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: iconSize),
            view.heightAnchor.constraint(equalToConstant: iconSize),
        ])
        return view
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            titleLabel.textColor = Palette.textPrimary
            detailLabel.textColor = Palette.textSecondary
            neverButton.color = Palette.textTertiary
            glass?.applyTheme()
        }
    }

    /// The card's lines and buttons as shown (tests, diagnostics).
    var shownText: [String] {
        [titleLabel.stringValue, detailLabel.stringValue] + (offer.neverTitle.map { [$0] } ?? []) + [offer.notNowTitle, offer.importTitle]
    }

    @objc private func importCookies() { onChoice?(.importCookies) }
    @objc private func notNow() { onChoice?(.notNow) }
    @objc private func never() { onChoice?(.never) }
}

/// A borderless text button drawn as a quiet link (tertiary text, an
/// underline while hovered): the card's least likely answer.
final class CookieCardLinkButton: NSButton {
    /// The card sets it on every theme pass; until then the app theme's tertiary ink.
    var color: NSColor = ThemeTokens.unresolved.textTertiary.nsColor { didSet { applyTitle() } }
    var textFont: NSFont = BrowserMetrics.captionFont { didSet { applyTitle() } }
    private var text = ""
    private var isHovering = false { didSet { applyTitle() } }
    private var tracking: NSTrackingArea?

    func configure(title: String, target: AnyObject, action: Selector) {
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        text = title
        self.target = target
        self.action = action
        setAccessibilityLabel(title)
        applyTitle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func applyTitle() {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: textFont]
        if isHovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: text, attributes: attributes)
        invalidateIntrinsicContentSize()
    }
}

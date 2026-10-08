import AppKit
import CmuxNextDesign

/// A small glass card at the bottom of the page that offers to bring the
/// person's cookies over from their other browsers: up to three browser
/// icons, one title, one line of detail, then Don't Show Again (a quiet
/// link), Not Now and Import Cookies. It never takes focus and every answer
/// closes it. Under Reduce Transparency it is opaque (`OverlaySurfaceView`).
final class BrowserCookieImportCard: NSView {
    static let maximumIcons = 3
    var onChoice: ((BrowserCookieImportChoice) -> Void)?
    /// Set while the close animation runs; a new offer then gets a new card.
    var isDismissing = false
    private(set) var offer: BrowserCookieImportOffer
    private let icons = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
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
        detailLabel.cell?.truncatesLastVisibleLine = true
        detailLabel.isSelectable = false
        neverButton.configure(title: offer.neverTitle, target: self, action: #selector(never))
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
        let content = OverlayBackingView()
        content.addSubview(stack)
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius)
        addSubview(glass)
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
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
        }
        density.start()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(offer.title)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        [titleLabel.stringValue, detailLabel.stringValue, neverButton.title, offer.notNowTitle, offer.importTitle]
    }

    var shownIconCount: Int { icons.arrangedSubviews.count }

    @objc private func importCookies() { onChoice?(.importCookies) }
    @objc private func notNow() { onChoice?(.notNow) }
    @objc private func never() { onChoice?(.never) }
}

/// A borderless text button drawn as a quiet link (tertiary text, an
/// underline while hovered): the card's least likely answer.
final class CookieCardLinkButton: NSButton {
    var color: NSColor = .secondaryLabelColor { didSet { applyTitle() } }
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

import AppKit
import CmuxNextDesign

/// The "Page unresponsive" choice, as a glass card over the page: Wait
/// restarts the engine's hang timer, Exit page ends the renderer (the tab
/// then shows `PageGoneView`). Shown only while the engine reports the hang.
final class PageUnresponsiveView: ChromeFrameView {
    var onWait: (() -> Void)?
    var onExit: (() -> Void)?
    private let titleLabel = ChromeLabel(labelWithString: Strings.pageUnresponsiveTitle)
    private let messageLabel = ChromeLabel(wrappingLabelWithString: Strings.pageUnresponsiveMessage)
    private let density = DensityBinding()
    /// The card's material: glass, or opaque under Reduce Transparency.
    private(set) var glass: OverlaySurfaceView?

    // Targets are set in init (no IUOs).
    private let exitButton = ChromeTextButton(title: Strings.pageUnresponsiveExit, prominent: false,
                                              action: #selector(PageUnresponsiveView.exitPage), target: nil)
    private let waitButton = ChromeTextButton(title: Strings.pageUnresponsiveWait, prominent: true,
                                              action: #selector(PageUnresponsiveView.waitForPage), target: nil)
    /// The card's content (the glass's), where the column lays out.
    private let content = OverlayBackingView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier(BrowserChromeView.pageUnresponsiveIdentifier)
        exitButton.setAccessibilityIdentifier(BrowserChromeView.pageUnresponsiveExitIdentifier)
        waitButton.setAccessibilityIdentifier(BrowserChromeView.pageUnresponsiveWaitIdentifier)
        messageLabel.maximumNumberOfLines = 4
        for view in [titleLabel, messageLabel, exitButton, waitButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(view)
        }
        for button in [exitButton, waitButton] { button.target = self }
        let glass = Glass.makeOverlayPanel(content: content, cornerRadius: BrowserMetrics.overlayCornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        self.glass = glass
        density.update { [weak self] in
            guard let self else { return }
            titleLabel.font = BrowserMetrics.emphasizedFont
            messageLabel.font = BrowserMetrics.bodyFont
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
            needsLayout = true // invalidate: a design token changed the card's sizes
            superview?.needsLayout = true // invalidate: the card's size follows the tokens; its owner places it
        }
        density.start(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card: title, message and the Exit page / Wait row, leading, with
    /// the overlay padding around and between them.
    var cardLayout: OverlayCardLayout {
        let padding = BrowserMetrics.overlayPadding
        return OverlayCardLayout(column: ChromeColumnLayout(spacing: padding, insets: ChromeInsets(all: padding),
                                                            alignment: .leading, rightToLeft: laysOutRightToLeft),
                                 minWidth: BrowserMetrics.promptMinWidth, maxWidth: BrowserMetrics.promptMaxWidth)
    }

    private var items: [ChromeColumnItem] {
        [.view(titleLabel), .view(messageLabel),
         .row([exitButton, waitButton], ChromeRowLayout(spacing: BrowserMetrics.itemSpacing, rightToLeft: laysOutRightToLeft))]
    }

    /// The card's size in a room `width` wide (its owner centers it there).
    func size(fittingWidth width: CGFloat) -> CGSize {
        cardLayout.measure(items, room: width)
    }

    override func layout() {
        super.layout()
        if let glass, glass.frame != bounds { glass.frame = bounds }
        cardLayout.column.layout(items, in: CGRect(origin: .zero, size: bounds.size))
    }

    // visibility-walk-allow: two text colors and the glass tint in the theme scope, no layout or text measure; cheaper than a deferral
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
            messageLabel.textColor = Palette.textSecondary
            glass?.applyTheme()
        }
    }

    @objc private func waitForPage() { onWait?() }
    @objc private func exitPage() { onExit?() }
}

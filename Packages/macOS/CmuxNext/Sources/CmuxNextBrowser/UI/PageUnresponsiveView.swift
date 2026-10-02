import AppKit
import CmuxNextDesign

/// The "Page unresponsive" choice, as a glass card over the page: Wait
/// restarts the engine's hang timer, Exit page ends the renderer (the tab
/// then shows `PageGoneView`). Shown only while the engine reports the hang.
final class PageUnresponsiveView: NSView {
    var onWait: (() -> Void)?
    var onExit: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: Strings.pageUnresponsiveTitle)
    private let messageLabel = NSTextField(wrappingLabelWithString: Strings.pageUnresponsiveMessage)
    private let density = DensityBinding()
    private var glass: NSGlassEffectView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(BrowserChromeView.pageUnresponsiveIdentifier)
        messageLabel.maximumNumberOfLines = 4
        let exit = ChromeTextButton(title: Strings.pageUnresponsiveExit, prominent: false, action: #selector(exitPage), target: self)
        exit.setAccessibilityIdentifier(BrowserChromeView.pageUnresponsiveExitIdentifier)
        let wait = ChromeTextButton(title: Strings.pageUnresponsiveWait, prominent: true, action: #selector(waitForPage), target: self)
        wait.setAccessibilityIdentifier(BrowserChromeView.pageUnresponsiveWaitIdentifier)
        let buttons = NSStackView(views: [exit, wait])
        let stack = NSStackView(views: [titleLabel, messageLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = OverlayBackingView()
        content.addSubview(stack)
        let glass = Glass.makePanel(content: content, style: .regular, cornerRadius: BrowserMetrics.overlayCornerRadius)
        addSubview(glass)
        self.glass = glass
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            density.bind(widthAnchor.constraint(lessThanOrEqualToConstant: 0)) { BrowserMetrics.promptMaxWidth },
            density.bind(widthAnchor.constraint(greaterThanOrEqualToConstant: 0).prioritized(.init(450))) { BrowserMetrics.promptMinWidth },
        ])
        density.update { [titleLabel, messageLabel] in
            let padding = BrowserMetrics.overlayPadding
            titleLabel.font = BrowserMetrics.emphasizedFont
            messageLabel.font = BrowserMetrics.bodyFont
            messageLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth - padding * 2
            buttons.spacing = BrowserMetrics.itemSpacing
            stack.spacing = padding
            stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
            glass.cornerRadius = BrowserMetrics.overlayCornerRadius
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
            glass?.tintColor = Palette.glassTint
        }
    }

    @objc private func waitForPage() { onWait?() }
    @objc private func exitPage() { onExit?() }
}

import AppKit
import CmuxNextDesign

/// Chrome's "sad tab": the page's content process ended. Covers the content
/// area (child-window pages get an occlusion hole there, so this view is
/// what the pane shows) and offers Reload, which starts a new process on the
/// same URL and history.
final class PageGoneView: NSView {
    var onReload: (() -> Void)?
    private let symbol = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let density = DensityBinding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier(BrowserChromeView.Identifier.pageGone)
        symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        messageLabel.alignment = .center
        codeLabel.isSelectable = true
        let reload = ChromeTextButton(title: Strings.pageGoneReload, prominent: true, action: #selector(reload), target: self)
        reload.setAccessibilityIdentifier(BrowserChromeView.Identifier.pageGoneReload)
        let stack = NSStackView(views: [symbol, titleLabel, messageLabel, reload, codeLabel])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            density.bind(stack.centerYAnchor.constraint(equalTo: centerYAnchor)) { -BrowserMetrics.toolbarHeight },
            density.bind(stack.widthAnchor.constraint(lessThanOrEqualToConstant: 0)) { BrowserMetrics.promptMaxWidth },
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])
        density.update { [titleLabel, messageLabel, codeLabel, symbol] in
            titleLabel.font = BrowserMetrics.errorTitleFont
            messageLabel.font = BrowserMetrics.bodyFont
            codeLabel.font = BrowserMetrics.captionFont
            messageLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth
            symbol.symbolConfiguration = .init(pointSize: BrowserMetrics.errorTitleFont.pointSize * 1.6, weight: .regular)
            stack.spacing = BrowserMetrics.overlayPadding
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ exit: BrowserProcessExit) {
        titleLabel.stringValue = Strings.pageGoneTitle(exit.reason)
        messageLabel.stringValue = Strings.pageGoneMessage(exit.reason)
        if let code = exit.codeDescription {
            codeLabel.stringValue = Strings.pageGoneErrorCode(code)
            codeLabel.isHidden = false
        } else {
            codeLabel.isHidden = true
        }
        isHidden = false
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.pageBackground.cgColor
            symbol.contentTintColor = Palette.textSecondary
            titleLabel.textColor = Palette.textPrimary
            messageLabel.textColor = Palette.textSecondary
            codeLabel.textColor = Palette.textTertiary
        }
    }

    @objc private func reload() { onReload?() }
}

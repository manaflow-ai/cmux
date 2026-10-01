import AppKit
import CmuxNextDesign

/// Shown over the content when a load fails.
final class LoadErrorView: NSView {
    var onRetry: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: Strings.loadFailedTitle)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let density = DensityBinding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        messageLabel.alignment = .center
        let retry = ChromeTextButton(title: Strings.tryAgain, prominent: true, action: #selector(retry), target: self)
        let stack = NSStackView(views: [titleLabel, messageLabel, retry])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            density.bind(stack.centerYAnchor.constraint(equalTo: centerYAnchor)) { -BrowserMetrics.toolbarHeight },
            density.bind(stack.widthAnchor.constraint(lessThanOrEqualToConstant: 0)) { BrowserMetrics.promptMaxWidth },
        ])
        density.update { [titleLabel, messageLabel] in
            titleLabel.font = BrowserMetrics.errorTitleFont
            messageLabel.font = BrowserMetrics.bodyFont
            messageLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth
            stack.spacing = BrowserMetrics.overlayPadding
        }
        density.start()
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ error: BrowserLoadError) {
        messageLabel.stringValue = error.message
        isHidden = false
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Opaque theme color: the failed page must not show through.
    private func updateColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.pageBackground.cgColor
            titleLabel.textColor = Palette.textPrimary
            messageLabel.textColor = Palette.textSecondary
        }
    }

    @objc private func retry() { onRetry?() }
}

import AppKit
import CmuxNextDesign

/// Shown over the content when a load fails. An untrusted certificate
/// shows the interstitial instead: Go Back (prominent) and an explicit
/// Proceed for that host (Chrome, Safari).
final class LoadErrorView: NSView {
    var onRetry: (() -> Void)?
    var onBack: (() -> Void)?
    var onProceed: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: Strings.loadFailedTitle)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var retryButton: ChromeTextButton!
    private(set) var backButton: ChromeTextButton!
    private(set) var proceedButton: ChromeTextButton!
    private(set) var isCertificateInterstitial = false
    private let density = DensityBinding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        messageLabel.alignment = .center
        let retry = ChromeTextButton(title: Strings.tryAgain, prominent: true, action: #selector(retry), target: self)
        let back = ChromeTextButton(title: Strings.certificateBack, prominent: true, action: #selector(goBack), target: self)
        let proceed = ChromeTextButton(title: "", prominent: false, action: #selector(proceed), target: self)
        retryButton = retry
        backButton = back
        proceedButton = proceed
        let stack = NSStackView(views: [titleLabel, messageLabel, retry, back, proceed])
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
        let host = error.failingURL?.host()
        isCertificateInterstitial = error.isCertificateError && host != nil
        if isCertificateInterstitial, let host {
            titleLabel.stringValue = Strings.certificateTitle
            messageLabel.stringValue = Strings.certificateMessage(host: host)
            proceedButton.title = Strings.certificateProceed(host: host)
        } else {
            titleLabel.stringValue = Strings.loadFailedTitle
            messageLabel.stringValue = error.message
        }
        retryButton.isHidden = isCertificateInterstitial
        backButton.isHidden = !isCertificateInterstitial
        proceedButton.isHidden = !isCertificateInterstitial
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
    @objc private func goBack() { onBack?() }
    @objc private func proceed() { onProceed?() }
}

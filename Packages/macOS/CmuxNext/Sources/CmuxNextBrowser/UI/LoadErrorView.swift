import AppKit
import CmuxNextDesign

/// Shown over the content when a load fails. An untrusted certificate
/// shows the full-page interstitial instead: Back to Safety is the default
/// (prominent, and Return on the page), and Proceed for that host shows
/// only after Show Details (Chrome, Safari).
final class LoadErrorView: NSView {
    var onRetry: (() -> Void)?
    var onBack: (() -> Void)?
    var onProceed: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: Strings.loadFailedTitle)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var retryButton: ChromeTextButton!
    private(set) var backButton: ChromeTextButton!
    private(set) var proceedButton: ChromeTextButton!
    private(set) var detailsButton: ChromeTextButton!
    let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var showsDetails = false
    private(set) var isCertificateInterstitial = false
    private let density = DensityBinding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        messageLabel.alignment = .center
        let retry = ChromeTextButton(title: Strings.tryAgain, prominent: true, action: #selector(retry), target: self)
        let back = ChromeTextButton(title: Strings.certificateBackToSafety, prominent: true, action: #selector(goBack), target: self)
        let proceed = ChromeTextButton(title: "", prominent: false, action: #selector(proceed), target: self)
        retryButton = retry
        backButton = back
        proceedButton = proceed
        detailsButton = ChromeTextButton(title: Strings.certificateShowDetails, prominent: false,
                                         action: #selector(toggleDetails), target: self)
        detailsLabel.alignment = .center
        let stack = NSStackView(views: [titleLabel, messageLabel, retry, back, detailsButton, detailsLabel, proceed])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            density.bind(stack.centerYAnchor.constraint(equalTo: centerYAnchor)) { -BrowserMetrics.toolbarHeight },
            density.bind(stack.widthAnchor.constraint(lessThanOrEqualToConstant: 0)) { BrowserMetrics.promptMaxWidth },
        ])
        density.update { [titleLabel, messageLabel, detailsLabel] in
            titleLabel.font = BrowserMetrics.errorTitleFont
            messageLabel.font = BrowserMetrics.bodyFont
            messageLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth
            detailsLabel.font = BrowserMetrics.bodyFont
            detailsLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth
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
            detailsLabel.stringValue = Strings.certificateDetails(host: host, reason: error.message)
        } else {
            titleLabel.stringValue = Strings.loadFailedTitle
            messageLabel.stringValue = error.message
        }
        retryButton.isHidden = isCertificateInterstitial
        backButton.isHidden = !isCertificateInterstitial
        showsDetails = false
        applyDetails()
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
            detailsLabel.textColor = Palette.textSecondary
        }
    }

    @objc private func retry() { onRetry?() }
    @objc private func goBack() { onBack?() }
    @objc private func proceed() { onProceed?() }

    @objc private func toggleDetails() {
        showsDetails.toggle()
        applyDetails()
    }

    /// Proceed and the details show only on the interstitial, after Show Details.
    private func applyDetails() {
        detailsButton.isHidden = !isCertificateInterstitial
        detailsButton.title = showsDetails ? Strings.certificateHideDetails : Strings.certificateShowDetails
        detailsLabel.isHidden = !(isCertificateInterstitial && showsDetails)
        proceedButton.isHidden = detailsLabel.isHidden
    }

    /// Return on the interstitial goes Back to Safety. A key handler on the
    /// page, not a button key equivalent: a window-wide Return equivalent
    /// would also catch Return typed in another pane.
    override var acceptsFirstResponder: Bool { isCertificateInterstitial }

    override func keyDown(with event: NSEvent) {
        if isCertificateInterstitial, event.keyCode == 36 || event.keyCode == 76 {
            goBack()
        } else {
            super.keyDown(with: event)
        }
    }
}

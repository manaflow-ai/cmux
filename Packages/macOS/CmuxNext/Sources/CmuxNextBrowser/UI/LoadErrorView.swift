import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// Shown over the content when a load fails. An untrusted certificate
/// shows the full-page interstitial instead: Back to Safety is the default
/// (prominent, and Return on the page), and Proceed for that host shows
/// only after Show Details (Chrome, Safari).
///
/// A network failure (``BrowserLoadError/isTransientNetworkFailure``) has no Try Again: the page reloads by itself
/// while in sight (`PageStatusViews`' ``AutoRetry``, Chrome's `NetErrorAutoReloader`), and the toolbar's Reload stays.
/// Leo, 2026-11-22: "vacuous decisions like that should be just done". Try Again shows only when loading again would
/// send a form (``BrowserLoadError/sentForm``), which the person chooses.
final class LoadErrorView: NSView {
    var onRetry: (() -> Void)?
    /// The page came into sight or left it: shown (not hidden), in a window not covered or minimized.
    var onSightChanged: ((Bool) -> Void)?
    var onBack: (() -> Void)?
    var onProceed: (() -> Void)?
    private let titleLabel = ChromeLabel(labelWithString: Strings.loadFailedTitle)
    private let messageLabel = ChromeLabel(wrappingLabelWithString: "")
    // Targets are set in init (no IUOs).
    // retry-prompt-ok: shown only when loading again would send a form (BrowserLoadError.sentForm, BR-R1)
    let retryButton = ChromeTextButton(title: Strings.tryAgain, prominent: true, action: #selector(LoadErrorView.retry), target: nil)
    let backButton = ChromeTextButton(title: Strings.certificateBackToSafety, prominent: true, action: #selector(LoadErrorView.goBack), target: nil)
    let proceedButton = ChromeTextButton(title: "", prominent: false, action: #selector(LoadErrorView.proceed), target: nil)
    let detailsButton = ChromeTextButton(title: Strings.certificateShowDetails, prominent: false, action: nil, target: nil)
    let detailsLabel = ChromeLabel(wrappingLabelWithString: "")
    private(set) var showsDetails = false
    private(set) var isCertificateInterstitial = false
    private let density = DensityBinding()
    private weak var followedWindow: NSWindow?
    private var reportedSight: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        messageLabel.alignment = .center
        let retry = retryButton, back = backButton, proceed = proceedButton
        for button in [retry, back, proceed] { button.target = self }
        detailsButton.action = #selector(toggleDetails)
        detailsButton.target = self
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
        // retry-prompt-ok: loading again would send a form or reload a form's result (BR-R1); every other failure
        // reloads by itself (a network failure) or is the toolbar Reload's.
        retryButton.isHidden = isCertificateInterstitial || !error.sentForm
        backButton.isHidden = !isCertificateInterstitial
        showsDetails = false
        applyDetails()
        isHidden = false
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let followedWindow { FrameScheduler.unfollowSight(of: followedWindow, owner: self) }
        followedWindow = window
        // The app's one occlusion observer tells this view (minimizing changes occlusion too).
        if let window { FrameScheduler.followSight(of: window, owner: self) { [weak self] in self?.reportSight() } }
        reportSight()
    }

    override func viewDidHide() {
        super.viewDidHide()
        reportSight()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reportSight()
    }

    /// Tells `onSightChanged` when the page's sight changed.
    private func reportSight() {
        let inSight = !isHiddenOrHasHiddenAncestor && window.map { !FrameScheduler.windowIsOutOfSight($0) } == true
        guard inSight != reportedSight else { return }
        reportedSight = inSight
        onSightChanged?(inSight)
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

    #if DEBUG
    /// The title and message shown (`debug.browser.page_status`).
    var debugText: String { "\(titleLabel.stringValue)\n\(messageLabel.stringValue)" }
    #endif

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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if isCertificateInterstitial, modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            goBack()
        } else {
            super.keyDown(with: event)
        }
    }
}

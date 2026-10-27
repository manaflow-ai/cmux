import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The "sad tab": the page's content process ended. Covers the content
/// area (child-window pages get an occlusion hole there, so this view is
/// what the pane shows) and offers Reload, which starts a new process on the
/// same URL and history.
final class PageGoneView: ChromeFrameView {
    var onReload: (() -> Void)?
    private let symbol = NSImageView()
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let messageLabel = ChromeLabel(wrappingLabelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let reloadButton = ChromeTextButton(title: Strings.pageGoneReload, prominent: true, action: #selector(reload), target: nil)
    private let density = DensityBinding()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier(BrowserChromeView.pageGoneIdentifier)
        messageLabel.alignment = .center
        codeLabel.isSelectable = true
        codeLabel.focusRingType = .none
        let reload = reloadButton
        reload.target = self
        reload.setAccessibilityIdentifier(BrowserChromeView.pageGoneReloadIdentifier)
        for view in [symbol, titleLabel, messageLabel, reload, codeLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        density.update { [weak self] in
            guard let self else { return }
            titleLabel.font = BrowserMetrics.errorTitleFont
            messageLabel.font = BrowserMetrics.bodyFont
            codeLabel.font = BrowserMetrics.captionFont
            // chrome-icons: allow a page body, not toolbar chrome
            symbol.image = NSImage.icon(.statusWarning, size: .iconRowSize(forLabelPointSize: BrowserMetrics.errorTitleFont.pointSize * 1.6))
            needsLayout = true // invalidate: a design token changed the sizes the column lays out
        }
        density.start(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let column: [NSView] = [symbol, titleLabel, messageLabel, reloadButton, codeLabel]
        PageMessageLayout.statusPage(rightToLeft: laysOutRightToLeft).layout(column, in: bounds)
    }

    func show(_ exit: BrowserProcessExit) {
        // A Chromium tab says what Chrome's sad tab says, and that Chromium stopped when its host ended.
        let chromium = exit.engine == .cef
        titleLabel.stringValue = chromium ? Strings.pageGoneChromiumTitle : Strings.pageGoneTitle(exit.reason)
        messageLabel.stringValue = switch (chromium, exit.process) {
        case (true, .chromiumHost): Strings.pageGoneChromiumHostMessage
        case (true, .page): Strings.pageGoneChromiumMessage
        case (false, _): Strings.pageGoneMessage(exit.reason)
        }
        if let code = exit.codeDescription {
            codeLabel.stringValue = Strings.pageGoneErrorCode(code)
            codeLabel.isHidden = false
        } else {
            codeLabel.isHidden = true
        }
        needsLayout = true // invalidate: the title, message or error code changed the column
        isHidden = false
        updateColors()
    }

    // visibility-walk-allow: five color stores (a layer color, a tint, three text colors) in the theme scope, no layout or text measure; cheaper than a deferral
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

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.browser.page_status`: the title, the message and the button the sad tab shows.
    var debugText: String { "\(titleLabel.stringValue)\n\(messageLabel.stringValue)\n\(reloadButton.isHidden ? "" : reloadButton.title)" }

    /// Presses Reload through its button, as a click does.
    func pressReload() { reloadButton.performClick(nil) }
    #endif
}

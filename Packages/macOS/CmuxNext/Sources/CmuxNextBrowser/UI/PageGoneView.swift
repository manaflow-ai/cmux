import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The "sad tab": the page's content process ended. Covers the content
/// area (child-window pages get an occlusion hole there, so this view is
/// what the pane shows) and offers Reload, which starts a new process on the
/// same URL and history.
final class PageGoneView: ChromeFrameView {
    var onReload: (() -> Void)?
    /// Reload All Tabs, shown only after the Chromium Host ended (every Chromium tab lost its page).
    var onReloadAll: (() -> Void)?
    private let symbol = NSImageView()
    private let titleLabel = ChromeLabel(labelWithString: "")
    private let messageLabel = ChromeLabel(wrappingLabelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let reloadButton = ChromeTextButton(title: Strings.pageGoneReload, prominent: true, action: #selector(reload), target: nil)
    private let reloadAllButton = ChromeTextButton(title: Strings.pageGoneReloadAllTabs, prominent: false, action: #selector(reloadAll), target: nil)
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
        reloadAllButton.target = self
        reloadAllButton.setAccessibilityIdentifier(BrowserChromeView.pageGoneReloadAllIdentifier)
        reloadAllButton.isHidden = true
        for view in [symbol, titleLabel, messageLabel, reload, reloadAllButton, codeLabel] as [NSView] {
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
        let column: [NSView] = [symbol, titleLabel, messageLabel, reloadButton, reloadAllButton, codeLabel]
        PageMessageLayout.statusPage(rightToLeft: laysOutRightToLeft).layout(column, in: bounds)
    }

    /// Shows `exit`'s crash page. `inMemoryOnly`: the tab's sign-ins and site data lived only in the ended
    /// process (an incognito Chromium tab whose host ended), so the page says they are gone.
    func show(_ exit: BrowserProcessExit, inMemoryOnly: Bool = false) {
        // A Chromium tab says what Chrome's sad tab says, and that Chromium stopped when its host ended.
        let chromium = exit.engine == .cef
        let hostEnded = chromium && exit.process == .chromiumHost
        titleLabel.stringValue = chromium ? Strings.pageGoneChromiumTitle : Strings.pageGoneTitle(exit.reason)
        messageLabel.stringValue = switch (chromium, exit.process) {
        case (true, .chromiumHost): inMemoryOnly ? Strings.pageGoneChromiumHostIncognitoMessage : Strings.pageGoneChromiumHostMessage
        case (true, .page): Strings.pageGoneChromiumMessage
        case (false, _): Strings.pageGoneMessage(exit.reason)
        }
        // Every Chromium tab lost its page with the host: one button brings them all back.
        reloadAllButton.isHidden = !hostEnded
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

    @objc private func reloadAll() { onReloadAll?() }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.browser.page_status`: the title, the message and the buttons the sad tab shows, three lines
    /// (the host-kill and child-crash e2e scripts read three); the buttons share the last, " · " between them.
    var debugText: String {
        let buttons = [reloadButton, reloadAllButton].filter { !$0.isHidden }.map(\.title).joined(separator: " · ")
        return "\(titleLabel.stringValue)\n\(messageLabel.stringValue)\n\(buttons)"
    }

    /// Presses Reload through its button, as a click does.
    func pressReload() { reloadButton.performClick(nil) }

    /// Presses Reload All Tabs through its button, as a click does.
    func pressReloadAll() { reloadAllButton.performClick(nil) }
    #endif
}

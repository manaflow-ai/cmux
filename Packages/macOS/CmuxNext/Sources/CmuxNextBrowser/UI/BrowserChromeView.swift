public import AppKit
import CmuxNextDesign

/// A browser pane: toolbar (back, forward, reload, omnibox, extension slot),
/// a progress line, and the tab's content with find bar, prompt bar, and
/// error overlays. Hides its toolbar while page content is fullscreen.
public final class BrowserChromeView: NSView {
    /// The tab on screen. Assigning swaps the content view in place.
    public var tab: any BrowserTab {
        didSet { attach(tab, replacing: oldValue) }
    }

    /// When true the chrome handles `BrowserChromeCommand.defaultShortcut`
    /// key equivalents itself. Turn off once the App layer routes those
    /// shortcuts through its own action registry.
    public var handlesDefaultShortcuts = true

    /// Empty container at the trailing end of the toolbar for extension
    /// action buttons (CEF) or other per-pane controls.
    public let extensionSlot = NSStackView()

    public let addressBar: AddressBarView

    private let toolbar = NSView()
    private let separator = NSView()
    private let backButton: ChromeIconButton
    private let forwardButton: ChromeIconButton
    private let reloadButton: ChromeIconButton
    private let progressLine = ProgressLineView()
    private let contentContainer = NSView()
    private let findBar = FindBarView()
    private let promptBar = PromptBarView()
    private let errorView = LoadErrorView()
    private var toolbarHeight: NSLayoutConstraint!
    private var observation: ObservationLoop?
    private var showsStop = false

    public static var toolbarHeight: CGFloat { BrowserMetrics.toolbarHeight }

    public init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine()) {
        self.tab = tab
        addressBar = AddressBarView(suggestionEngine: suggestionEngine)
        backButton = ChromeIconButton(symbol: "chevron.left", label: Strings.back, action: nil, target: nil)
        forwardButton = ChromeIconButton(symbol: "chevron.right", label: Strings.forward, action: nil, target: nil)
        reloadButton = ChromeIconButton(symbol: "arrow.clockwise", label: Strings.reload, action: nil, target: nil)
        super.init(frame: .zero)
        wantsLayer = true
        buildLayout()
        wireActions()
        attach(tab, replacing: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Commands

    public func perform(_ command: BrowserChromeCommand) {
        switch command {
        case .focusAddressBar: addressBar.focus()
        case .findInPage: showFindBar()
        case .findNext: findBar.isHidden ? showFindBar() : findBar.findNext()
        case .findPrevious: findBar.isHidden ? showFindBar() : findBar.findPrevious()
        case .reload: tab.reload()
        case .stop: tab.stop()
        case .goBack: tab.goBack()
        case .goForward: tab.goForward()
        case .zoomIn: tab.zoomIn()
        case .zoomOut: tab.zoomOut()
        case .resetZoom: tab.resetZoom()
        case .showDevTools: tab.showDevTools()
        }
    }

    public func showFindBar() {
        if findBar.isHidden {
            findBar.isHidden = false
            findBar.alphaValue = 0
            Motion.animate(duration: 0.14) { self.findBar.animator().alphaValue = 1 }
        }
        findBar.focus()
    }

    public func hideFindBar() {
        guard !findBar.isHidden else { return }
        Motion.animate(duration: 0.12, { self.findBar.animator().alphaValue = 0 }) {
            self.findBar.isHidden = true
        }
        tab.setFocused(true)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard handlesDefaultShortcuts, containsFirstResponder,
              let command = BrowserChromeCommand.matching(event) else {
            return super.performKeyEquivalent(with: event)
        }
        perform(command)
        return true
    }

    // MARK: Layout

    private func buildLayout() {
        for view in [toolbar, separator, contentContainer, progressLine, findBar, promptBar, errorView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        toolbar.wantsLayer = true
        separator.wantsLayer = true
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        extensionSlot.orientation = .horizontal
        extensionSlot.spacing = BrowserMetrics.buttonSpacing
        extensionSlot.setAccessibilityLabel(Strings.extensions)

        let navigation = NSStackView(views: [backButton, forwardButton, reloadButton])
        navigation.spacing = BrowserMetrics.buttonSpacing
        navigation.translatesAutoresizingMaskIntoConstraints = false
        // NSStackView hugs through its own API, not content hugging. The
        // address bar has no intrinsic width and takes the remaining space.
        navigation.setHuggingPriority(.required, for: .horizontal)
        extensionSlot.setHuggingPriority(.required, for: .horizontal)
        addressBar.setContentHuggingPriority(.init(1), for: .horizontal)
        extensionSlot.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(navigation)
        toolbar.addSubview(addressBar)
        toolbar.addSubview(extensionSlot)

        addSubview(contentContainer)
        addSubview(toolbar)
        addSubview(separator)
        addSubview(progressLine)
        addSubview(errorView)
        addSubview(promptBar)
        addSubview(findBar)

        toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarHeight,
            navigation.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: BrowserMetrics.toolbarInset),
            navigation.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addressBar.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: BrowserMetrics.itemSpacing),
            addressBar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            extensionSlot.leadingAnchor.constraint(equalTo: addressBar.trailingAnchor, constant: BrowserMetrics.itemSpacing),
            extensionSlot.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -BrowserMetrics.toolbarInset),
            extensionSlot.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            extensionSlot.heightAnchor.constraint(equalToConstant: BrowserMetrics.controlHeight),
            addressBar.widthAnchor.constraint(greaterThanOrEqualToConstant: BrowserMetrics.minimumAddressWidth),

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: BrowserMetrics.separatorThickness),

            progressLine.bottomAnchor.constraint(equalTo: separator.bottomAnchor),
            progressLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: BrowserMetrics.progressThickness),

            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            errorView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            findBar.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: BrowserMetrics.overlayInset),
            findBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -BrowserMetrics.overlayInset),

            promptBar.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: BrowserMetrics.overlayInset),
            promptBar.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            promptBar.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: BrowserMetrics.overlayInset),
        ])

        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        promptBar.isHidden = true
        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.tab.reload() }
        updateColors()
    }

    private func wireActions() {
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        reloadButton.target = self
        reloadButton.action = #selector(reloadOrStop)
        addressBar.onNavigate = { [weak self] url in
            guard let self else { return }
            self.tab.load(url)
            self.tab.setFocused(true)
        }
        addressBar.onCancel = { [weak self] in self?.tab.setFocused(true) }
    }

    @objc private func goBack() { tab.goBack() }
    @objc private func goForward() { tab.goForward() }
    @objc private func reloadOrStop() { showsStop ? tab.stop() : tab.reload() }

    // MARK: Tab binding

    private func attach(_ tab: any BrowserTab, replacing old: (any BrowserTab)?) {
        observation?.cancel()
        if let old, old !== tab {
            old.contentView.removeFromSuperview()
        }
        let content = tab.contentView
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        findBar.tab = tab
        if !findBar.isHidden {
            old?.clearFind()
            findBar.isHidden = true
        }
        observation = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        let state = tab.state
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward

        let loading = state.isLoading
        if loading != showsStop {
            showsStop = loading
            reloadButton.setSymbol(loading ? "xmark" : "arrow.clockwise", label: loading ? Strings.stop : Strings.reload)
        }
        addressBar.update(url: state.url, security: state.security)
        progressLine.set(progress: state.progress, visible: loading)

        if let error = state.loadError {
            errorView.show(error)
        } else if !errorView.isHidden {
            errorView.isHidden = true
        }

        if let prompt = tab.pendingPrompts.first {
            promptBar.show(prompt)
            promptBar.isHidden = false
        } else {
            promptBar.isHidden = true
        }

        setToolbarHidden(state.isContentFullscreen)
    }

    private func setToolbarHidden(_ hidden: Bool) {
        let height = hidden ? 0 : Self.toolbarHeight
        guard toolbarHeight.constant != height else { return }
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        Motion.animate(duration: 0.2, {
            self.toolbarHeight.animator().constant = height
            self.layoutSubtreeIfNeeded()
        }) {
            if self.toolbarHeight.constant == 0 {
                self.toolbar.isHidden = true
                self.separator.isHidden = true
            }
        }
    }

    private var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let view = responder as? NSView { return view.isDescendant(of: self) }
        if let editor = responder as? NSText, let delegate = editor.delegate as? NSView {
            return delegate.isDescendant(of: self)
        }
        return false
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.contentBackground.cgColor
            toolbar.layer?.backgroundColor = Palette.windowBackground.cgColor
            separator.layer?.backgroundColor = Palette.separator.cgColor
        }
    }
}

/// Thin gray load progress line under the toolbar.
final class ProgressLineView: NSView {
    private let bar = CALayer()
    private var progress: Double = 0
    private var visible = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bar)
        bar.anchorPoint = .zero
        bar.opacity = 0
        updateColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(progress: Double, visible: Bool) {
        let wasVisible = self.visible
        self.progress = visible ? progress : (wasVisible ? 1 : 0)
        self.visible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(Motion.reduced || (!wasVisible && visible))
        CATransaction.setAnimationDuration(0.2)
        layoutBar()
        if visible {
            bar.opacity = 1
        } else if wasVisible {
            bar.opacity = 0
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBar()
        CATransaction.commit()
    }

    private func layoutBar() {
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.backgroundColor = Palette.focusRing.withAlphaComponent(0.8).cgColor
        }
    }
}

/// Shown over the content when a load fails.
final class LoadErrorView: NSView {
    var onRetry: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: Strings.loadFailedTitle)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        titleLabel.font = BrowserMetrics.errorTitleFont
        titleLabel.textColor = Palette.textPrimary
        messageLabel.font = BrowserMetrics.bodyFont
        messageLabel.textColor = Palette.textSecondary
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = BrowserMetrics.promptMaxWidth
        let retry = ChromeTextButton(title: Strings.tryAgain, prominent: true, action: #selector(retry), target: self)
        let stack = NSStackView(views: [titleLabel, messageLabel, retry])
        stack.orientation = .vertical
        stack.spacing = BrowserMetrics.overlayPadding
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -BrowserMetrics.toolbarHeight),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: BrowserMetrics.promptMaxWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ error: BrowserLoadError) {
        messageLabel.stringValue = error.message
        isHidden = false
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.contentBackground.cgColor
        }
    }

    @objc private func retry() { onRetry?() }
}

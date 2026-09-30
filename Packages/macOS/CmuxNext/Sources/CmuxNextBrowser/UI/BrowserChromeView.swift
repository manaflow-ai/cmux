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

    /// Which part of the chrome holds a responder view.
    public enum Region: Hashable, Sendable {
        case addressBar
        case findBar
        case page
        /// Toolbar buttons, prompt bar, error page.
        case chrome
    }

    /// Browser focus mode (the page gets every key but app-level ones):
    /// a thin gray inset outline around the page.
    public var showsFocusModeIndicator = false {
        didSet {
            guard showsFocusModeIndicator != oldValue else { return }
            contentContainer.layer?.borderWidth = showsFocusModeIndicator ? 2 : 0
            updateColors()
        }
    }

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
    private var isToolbarHidden = false
    private let density = DensityBinding()
    private lazy var extensionToolbar = ExtensionActionToolbar(slot: extensionSlot)

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
            updateOcclusion()
        }
        findBar.focus()
    }

    public func hideFindBar() {
        guard !findBar.isHidden else { return }
        Motion.animate(duration: 0.12, { self.findBar.animator().alphaValue = 0 }) {
            self.findBar.isHidden = true
            self.updateOcclusion()
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
        extensionSlot.setAccessibilityLabel(Strings.extensions)

        let navigation = NSStackView(views: [backButton, forwardButton, reloadButton])
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

        toolbarHeight = density.bind(toolbar.heightAnchor.constraint(equalToConstant: 0)) { [unowned self] in
            isToolbarHidden ? 0 : Self.toolbarHeight
        }
        density.update { [extensionSlot] in
            extensionSlot.spacing = BrowserMetrics.buttonSpacing
            navigation.spacing = BrowserMetrics.buttonSpacing
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarHeight,
            density.bind(navigation.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor)) { BrowserMetrics.toolbarInset },
            navigation.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            density.bind(addressBar.leadingAnchor.constraint(equalTo: navigation.trailingAnchor)) { BrowserMetrics.itemSpacing },
            addressBar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            density.bind(extensionSlot.leadingAnchor.constraint(equalTo: addressBar.trailingAnchor)) { BrowserMetrics.itemSpacing },
            density.bind(extensionSlot.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor)) { -BrowserMetrics.toolbarInset },
            extensionSlot.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            density.bind(extensionSlot.heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.controlHeight },
            density.bind(addressBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)) { BrowserMetrics.minimumAddressWidth },

            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            density.bind(separator.heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.separatorThickness },

            progressLine.bottomAnchor.constraint(equalTo: separator.bottomAnchor),
            progressLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            density.bind(progressLine.heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.progressThickness },

            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            errorView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            density.bind(findBar.topAnchor.constraint(equalTo: contentContainer.topAnchor)) { BrowserMetrics.overlayInset },
            density.bind(findBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)) { -BrowserMetrics.overlayInset },

            density.bind(promptBar.topAnchor.constraint(equalTo: contentContainer.topAnchor)) { BrowserMetrics.overlayInset },
            promptBar.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            density.bind(promptBar.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor)) { BrowserMetrics.overlayInset },
        ])

        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        promptBar.isHidden = true
        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.tab.reload() }
        density.start()
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
        extensionToolbar.bind(tab)
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
        updateOcclusion()
    }

    public override func layout() {
        super.layout()
        updateOcclusion()
    }

    /// Child-window pages draw above this view; tell them where the find
    /// bar, prompt bar, and error page cover them.
    private func updateOcclusion() {
        guard let occluded = tab as? any BrowserOcclusionHosting else { return }
        let content = tab.contentView
        let rects = [findBar, promptBar, errorView as NSView]
            .filter { !$0.isHidden && $0.superview != nil }
            .map { convert($0.frame, to: content) }
        if occluded.occlusionRects != rects { occluded.occlusionRects = rects }
    }

    private func setToolbarHidden(_ hidden: Bool) {
        guard hidden != isToolbarHidden else { return }
        isToolbarHidden = hidden
        let height = hidden ? 0 : Self.toolbarHeight
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        Motion.animate(duration: 0.2, {
            self.toolbarHeight.animator().constant = height
            self.layoutSubtreeIfNeeded()
        }) {
            if self.isToolbarHidden {
                self.toolbar.isHidden = true
                self.separator.isHidden = true
            }
        }
    }

    /// The region of this chrome that contains `view`, nil when outside.
    public func region(of view: NSView) -> Region? {
        guard view.isDescendant(of: self) else { return nil }
        if view.isDescendant(of: addressBar) { return .addressBar }
        if view.isDescendant(of: findBar) { return .findBar }
        if view.isDescendant(of: tab.contentView) { return .page }
        return .chrome
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
            contentContainer.layer?.borderColor = Palette.separator.cgColor
        }
    }
}

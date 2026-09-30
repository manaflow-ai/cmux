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
    public private(set) lazy var pageInfo = makePageInfoController()

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

    let toolbar = NSView()
    private let separator = NSView()
    let backButton: ChromeIconButton
    let forwardButton: ChromeIconButton
    let reloadButton: ChromeIconButton
    private let progressLine = ProgressLineView()
    /// The page area: the page, docked DevTools and the page overlays. The
    /// pane's rounded corners clip it (`PaneContentChrome`).
    let contentContainer = NSView()
    public var onPaneHeaderHeightChange: (() -> Void)?
    private var reportedHeader: CGFloat = -1
    let findBar = FindBarView()
    private let promptBar = PromptBarView()
    private let pageStatus = PageStatusViews()
    private var toolbarHeight: NSLayoutConstraint!
    private var observation: ObservationLoop?
    private var showsStop = false
    private var isToolbarHidden = false
    private let density = DensityBinding()
    lazy var extensionToolbar: ExtensionActionToolbar = {
        let toolbar = ExtensionActionToolbar(slot: extensionSlot)
        toolbar.onPinnedCountChange = { [weak self] in self?.applyToolbarLayout() }
        return toolbar
    }()

    public static var toolbarHeight: CGFloat { OmnibarStyle.toolbarHeight }

    var toolbarLayout = BrowserToolbarLayout(visiblePinned: ExtensionActionToolbar.maxVisible, showsForward: true)

    /// Omnibar editing boundaries. When set, the App owns focus: the chrome
    /// only loads a committed URL and never moves focus itself. When nil,
    /// commit and cancel return focus to the page.
    public var onOmnibarEvent: ((OmnibarEvent) -> Void)?

    /// A modified omnibar commit (Cmd-Enter, Cmd-click): the host opens `url`
    /// in another tab or window. When nil, this tab loads it.
    public var onOpenURL: ((URL, OmnibarDisposition) -> Void)?

    /// Where finished page loads are recorded (omnibar history suggestions).
    public var history: (any BrowserHistoryStore)?

    /// Closing the find bar or ending address bar editing hands the keyboard
    /// back to the page. When set, the host does it (a focus coordinator
    /// that also tracks Chromium page windows); else the chrome focuses the
    /// page itself.
    public var onReturnFocusToPage: (() -> Void)?
    public var machineBadge: ((URL?) -> (text: String, help: String)?)? { didSet { updateMachineBadge() } } // remote localhost
    var recordedURL: URL?
    var recordedTitle: String?

    public init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine()) {
        self.tab = tab
        addressBar = AddressBarView(suggestionEngine: suggestionEngine)
        // Helium/Chromium toolbar glyphs: plain arrows, not chevrons.
        backButton = ChromeIconButton(symbol: "arrow.left", label: Strings.back, action: nil, target: nil, toolbar: true)
        forwardButton = ChromeIconButton(symbol: "arrow.right", label: Strings.forward, action: nil, target: nil, toolbar: true)
        reloadButton = ChromeIconButton(symbol: "arrow.clockwise", label: Strings.reload, action: nil, target: nil, toolbar: true)
        super.init(frame: .zero)
        wantsLayer = true
        backButton.setAccessibilityIdentifier(Identifier.back)
        forwardButton.setAccessibilityIdentifier(Identifier.forward)
        reloadButton.setAccessibilityIdentifier(Identifier.reload)
        addressBar.setAccessibilityIdentifier(Identifier.omnibar)
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
            Motion.animate(.fadeIn) { self.findBar.animator().alphaValue = 1 }
            updateOcclusion()
        }
        findBar.focus()
    }

    public func hideFindBar() {
        guard !findBar.isHidden else { return }
        Motion.animate(.fadeOut, { self.findBar.animator().alphaValue = 0 }, completion: {
            self.findBar.isHidden = true
            self.updateOcclusion()
        })
        returnFocusToPage()
    }

    func returnFocusToPage() {
        if let onReturnFocusToPage { onReturnFocusToPage() } else { tab.setFocused(true) }
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
        for view in [toolbar, separator, contentContainer, progressLine, findBar, promptBar] as [NSView] {
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
        pageStatus.install(in: self, over: contentContainer) { [weak self] in self?.tab }
        addSubview(promptBar)
        addSubview(findBar)

        toolbarHeight = density.bind(toolbar.heightAnchor.constraint(equalToConstant: 0)) { [unowned self] in
            isToolbarHidden ? 0 : Self.toolbarHeight
        }
        density.update { [extensionSlot] in
            extensionSlot.spacing = BrowserMetrics.buttonSpacing
            navigation.spacing = OmnibarStyle.buttonSpacing
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarHeight,
            density.bind(navigation.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor)) { OmnibarStyle.toolbarInset },
            navigation.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            density.bind(addressBar.leadingAnchor.constraint(equalTo: navigation.trailingAnchor)) { OmnibarStyle.barMargin },
            addressBar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            density.bind(extensionSlot.leadingAnchor.constraint(equalTo: addressBar.trailingAnchor)) { OmnibarStyle.barMargin },
            density.bind(extensionSlot.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor)) { -OmnibarStyle.toolbarInset },
            extensionSlot.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            density.bind(extensionSlot.heightAnchor.constraint(equalToConstant: 0)) { OmnibarStyle.buttonSize },
            // Soft minimums below the window's stay-put priority (500): the
            // omnibar never widens the pane or the window. BrowserToolbarLayout
            // hides extension buttons and Forward so these hold when possible.
            density.bind(addressBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).prioritized(.init(490))) {
                BrowserMetrics.minimumAddressWidth
            },
            density.bind(addressBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).prioritized(.init(480))) {
                OmnibarStyle.buttonSize
            },

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

            density.bind(findBar.topAnchor.constraint(equalTo: contentContainer.topAnchor)) { BrowserMetrics.overlayInset },
            density.bind(findBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)) { -BrowserMetrics.overlayInset },
            density.bind(findBar.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor)) { BrowserMetrics.overlayInset },

            density.bind(promptBar.topAnchor.constraint(equalTo: contentContainer.topAnchor)) { BrowserMetrics.overlayInset },
            promptBar.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            density.bind(promptBar.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor)) { BrowserMetrics.overlayInset },
        ])

        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        promptBar.isHidden = true
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
        addressBar.onEvent = { [weak self] event in self?.omnibarEvent(event) }
    }

    private func omnibarEvent(_ event: OmnibarEvent) {
        if case .didEndEditing(.commit(let url)) = event { tab.load(url) }
        if case .didEndEditing(.open(let url, let disposition)) = event { onOpenURL.map { $0(url, disposition) } ?? tab.load(url) }
        if let onOmnibarEvent { return onOmnibarEvent(event) }
        switch event {
        case .didEndEditing(.commit), .didEndEditing(.open), .didEndEditing(.cancel): returnFocusToPage()
        case .didBeginEditing, .didEndEditing(.blur): break
        }
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
        pageInfo.tabDidChange()
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
        addressBar.allowsChromiumSchemes = tab.engineKind == .cef
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
        addressBar.update(url: state.url, security: PageInfoSite.omnibarSecurity(for: state))
        updateMachineBadge()
        recordHistory(state)
        progressLine.set(progress: state.progress, visible: loading)

        pageStatus.render(state)

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
        applyToolbarLayout()
        super.layout()
        updateOcclusion()
        if pageAreaTop != reportedHeader {
            reportedHeader = pageAreaTop
            onPaneHeaderHeightChange?()
        }
    }

    /// Child-window pages draw above this view; tell them where the find
    /// bar, prompt bar, and error page cover them.
    private func updateOcclusion() {
        guard let occluded = tab as? any BrowserOcclusionHosting else { return }
        let content = tab.contentView
        var candidates: [NSView] = [findBar, promptBar]
        if let notice = currentNotice { candidates.append(notice) }
        let bars = candidates.filter { !$0.isHidden && $0.superview != nil }
        let rects = (bars + pageStatus.shown).map { convert($0.frame, to: content) }
        if occluded.occlusionRects != rects { occluded.occlusionRects = rects }
    }

    private func setToolbarHidden(_ hidden: Bool) {
        guard hidden != isToolbarHidden else { return }
        isToolbarHidden = hidden
        let height = hidden ? 0 : Self.toolbarHeight
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        Motion.animateTimed(hidden ? .disappear : .appear, {
            self.toolbarHeight.animator().constant = height
            self.layoutSubtreeIfNeeded()
        }, completion: {
            if self.isToolbarHidden {
                self.toolbar.isHidden = true
                self.separator.isHidden = true
            }
        })
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
            toolbar.layer?.backgroundColor = OmnibarStyle.toolbarBackground.cgColor
            separator.layer?.backgroundColor = Palette.separator.cgColor
            contentContainer.layer?.borderColor = Palette.separator.cgColor
        }
    }
}

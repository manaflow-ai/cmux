public import AppKit
public import CmuxNextDesign
import CmuxNextIcons

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
    /// Design mode, profile, theme, DevTools and More, after the extension slot.
    public let toolbarButtons = BrowserToolbarButtonsView()

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
    /// a thin gray inset outline around the page and the omnibar's "Focus
    /// Mode" badge (classic cmux parity).
    public var showsFocusModeIndicator = false {
        didSet {
            guard showsFocusModeIndicator != oldValue else { return }
            if !showsFocusModeIndicator { focusModeExitArmed = false }
            contentContainer.layer?.borderWidth = Metrics.lineWidth(showsFocusModeIndicator ? 2 : 0)
            updateColors()
            updateFocusModeBadge()
        }
    }

    /// The first Escape of focus mode's Esc Esc exit was pressed: the badge
    /// reads "Esc again to exit".
    public var focusModeExitArmed = false {
        didSet { if focusModeExitArmed != oldValue { updateFocusModeBadge() } }
    }

    /// A click on the focus mode badge: the host leaves focus mode.
    public var onFocusModeBadgePress: (() -> Void)? {
        get { addressBar.focusModeBadgeView.onPress }
        set { addressBar.focusModeBadgeView.onPress = newValue }
    }

    private func updateFocusModeBadge() {
        addressBar.setFocusModeBadge(armed: showsFocusModeIndicator ? focusModeExitArmed : nil)
    }

    /// The arrow over the whole row (`OmnibarPointer`).
    let toolbar = ArrowCursorView()
    let separator = NSView()
    /// Holds an optional bar under the toolbar (the bookmarks bar); zero high when empty.
    let accessoryBar = NSView()
    var accessoryHeight: CGFloat = 0
    let backButton: ChromeIconButton
    let forwardButton: ChromeIconButton
    let reloadButton: ChromeIconButton
    private let progressLine = ProgressLineView()
    /// The page area: the page, docked DevTools and the page overlays. It is
    /// square; the pane's one rounded content area clips this whole view.
    let contentContainer = NSView()
    public var onPaneHeaderHeightChange: (() -> Void)?
    /// The page entered (true) or left (false) element fullscreen: the host may give it the whole
    /// screen, as Chrome does (`WindowController+FullScreen`).
    public var onContentFullscreenChange: ((Bool) -> Void)?
    private var reportedContentFullscreen = false
    /// The band under the toolbar rows for the pane's tab strip (R109).
    let headerBand = BrowserHeaderBand()
    let findBar = FindBarView()
    private let promptBar = PromptBarView()
    private let promptDialogs = BrowserPromptDialogs()
    let pageStatus = PageStatusViews()
    lazy var pageOverlays = PageFloatingOverlays(page: contentContainer)
    /// Bound in setup (first read there), never an IUO.
    lazy var toolbarHeight: NSLayoutConstraint = density.bind(toolbar.heightAnchor.constraint(equalToConstant: 0)) { [weak self] in
        // A deallocated chrome view's constraint is never laid out again.
        guard let self else { return 0 }
        return isToolbarHidden ? 0 : currentToolbarHeight
    }
    private var observation: ObservationLoop?
    /// Prompts have their own loop: a state change (a title, progress) does not re-render the prompt
    /// bar, and a new prompt does not re-run the rest of the chrome.
    private var promptObservation: ObservationLoop?
    /// The address a page woken from hibernation slept on, shown until the
    /// woken page reports a real one (`holdAddress(whileWaking:)`).
    var wakingAddress: BrowserTabState?
    /// A typed https upgrade in flight (Chrome's http fallback).
    var httpsFallback = HTTPSUpgradeFallback()
    private var showsStop = false
    var isToolbarHidden = false
    /// The edge the toolbar rows sit on (`browser.toolbarPosition`); the pane sets it.
    public var toolbarPosition: ToolbarPosition = .top {
        didSet { if toolbarPosition != oldValue { applyToolbarPosition() } }
    }
    /// The constraints that put the toolbar rows, page and page bars at the top or bottom.
    let toolbarEdge = ToolbarEdgeConstraints()
    /// The person hid this tab's address bar row (Toggle Omnibar).
    public internal(set) var isOmnibarHidden = false
    private let density = DensityBinding()
    lazy var extensionToolbar: ExtensionActionToolbar = {
        let toolbar = ExtensionActionToolbar(slot: extensionSlot)
        toolbar.onPinnedCountChange = { [weak self] in self?.applyToolbarLayout() }
        // An extension popup opened while the Extensions button is not placed anchors at More.
        toolbar.menuAnchor = { [weak self] in self?.toolbarButtons.anchor(for: .overflow) }
        return toolbar
    }()

    /// R101: the toolbar height on this window's pixel grid (else the main screen's).
    var currentToolbarHeight: CGFloat { OmnibarStyle.toolbarHeight(scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    /// Zoom per site (`SiteZoomLevels`).
    let siteZoom = SiteZoomFollower()
    var toolbarLayout = BrowserToolbarLayout(visiblePinned: ExtensionActionToolbar.maxVisible, showsForward: true)

    /// Omnibar editing boundaries. When set, the App owns focus: the chrome
    /// only loads a committed URL and never moves focus itself. When nil,
    /// commit and cancel return focus to the page.
    public var onOmnibarEvent: ((OmnibarEvent) -> Void)?

    /// Modified commits (Cmd-Enter) open elsewhere, nil: here; `loadOverride` true: the host served it (`cmux://history`).
    public var onOpenURL: ((URL, OmnibarDisposition) -> Void)?
    public var loadOverride: ((URL) -> Bool)?
    /// A committed URL loads in this tab (a typed navigation).
    public var onTypedCommit: (() -> Void)?

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
    /// Each page that finished loading, once per URL (the App's cookie import offer).
    public var onPageFinished: ((URL) -> Void)?
    var finishedURL: URL?

    public init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine()) {
        self.tab = tab
        addressBar = AddressBarView(suggestionEngine: suggestionEngine)
        // Chromium toolbar glyphs: plain arrows, not chevrons.
        backButton = ChromeIconButton(icon: .browserToolbarBack, label: Strings.back, action: nil, target: nil, toolbar: true, toolTip: false)
        forwardButton = ChromeIconButton(icon: .browserToolbarForward, label: Strings.forward, action: nil, target: nil, toolbar: true, toolTip: false)
        reloadButton = ChromeIconButton(icon: .browserToolbarReload, label: Strings.reload, action: nil, target: nil, toolbar: true, toolTip: false)
        super.init(frame: .zero)
        wantsLayer = true
        backButton.setAccessibilityIdentifier(BrowserChromeView.backIdentifier)
        forwardButton.setAccessibilityIdentifier(BrowserChromeView.forwardIdentifier)
        reloadButton.setAccessibilityIdentifier(BrowserChromeView.reloadIdentifier)
        addressBar.setAccessibilityIdentifier(BrowserChromeView.omnibarIdentifier)
        buildLayout()
        wireActions()
        attach(tab, replacing: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func showFindBar() {
        if findBar.isHidden {
            findBar.isHidden = false
            findBar.alphaValue = 0
            Motion.overlays.animate(.fadeIn, in: findBar) { self.findBar.animator().alphaValue = 1 }
            updateOcclusion()
        }
        findBar.focus()
    }

    public func hideFindBar() {
        guard !findBar.isHidden else { return }
        Motion.overlays.animate(.fadeOut, in: findBar, { self.findBar.animator().alphaValue = 0 }, completion: {
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
        for view in [toolbar, separator, accessoryBar, contentContainer, progressLine, findBar, promptBar] as [NSView] {
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
        toolbar.addSubview(toolbarButtons)

        addSubview(contentContainer)
        addSubview(toolbar)
        addSubview(separator)
        installAccessoryBar(below: separator)
        installHeaderBand(beside: accessoryBar)
        addSubview(progressLine)
        pageStatus.install(in: self, over: contentContainer) { [weak self] in self?.tab }
        addSubview(promptBar)
        addSubview(findBar)

        _ = toolbarHeight  // binds it here, in the same order as before
        let scale = { [weak self] in self?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
        // From the top: toolbar, separator, accessory bar, band, page. From the bottom: the same
        // rows mirrored, the page on top (`ToolbarEdgeConstraints`).
        toolbarEdge.top += [
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            density.bind(addressBar.topAnchor.constraint(equalTo: toolbar.topAnchor)) { OmnibarStyle.barTop(scale: scale()) }, // R101 gaps
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progressLine.bottomAnchor.constraint(equalTo: separator.bottomAnchor),
            // The page starts under the header band (empty unless the pane's
            // tab bar sits below the toolbar, R109).
            contentContainer.topAnchor.constraint(equalTo: headerBand.guide.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The shared find pill sits where every pane's does.
            findBar.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: FindPillMetrics.inset),
            density.bind(promptBar.topAnchor.constraint(equalTo: contentContainer.topAnchor)) { BrowserMetrics.overlayInset },
        ]
        toolbarEdge.bottom += [
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor),
            density.bind(addressBar.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)) { -OmnibarStyle.barTop(scale: scale()) },
            separator.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            progressLine.topAnchor.constraint(equalTo: separator.topAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: headerBand.guide.topAnchor),
            // The page's bars sit by the toolbar, at the page's bottom.
            findBar.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -FindPillMetrics.inset),
            density.bind(promptBar.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)) { -BrowserMetrics.overlayInset },
        ]
        toolbarEdge.activate(toolbarPosition)
        density.update { [extensionSlot, toolbarButtons] in
            extensionSlot.spacing = OmnibarStyle.buttonSpacing
            toolbarButtons.spacing = OmnibarStyle.buttonSpacing
            navigation.spacing = OmnibarStyle.buttonSpacing
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarHeight,
            density.bind(navigation.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor)) { OmnibarStyle.toolbarInset },
            navigation.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),
            density.bind(addressBar.leadingAnchor.constraint(equalTo: navigation.trailingAnchor)) { OmnibarStyle.barMargin },
            density.bind(extensionSlot.leadingAnchor.constraint(equalTo: addressBar.trailingAnchor)) { OmnibarStyle.barMargin },
            density.bind(toolbarButtons.leadingAnchor.constraint(equalTo: extensionSlot.trailingAnchor)) { OmnibarStyle.buttonSpacing },
            density.bind(toolbarButtons.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor)) { -OmnibarStyle.toolbarInset },
            // On the omnibar's vertical center, wherever the row places the omnibar.
            toolbarButtons.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),
            extensionSlot.centerYAnchor.constraint(equalTo: addressBar.centerYAnchor),
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

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            // No line between the omnibar and the page (Lawrence 2026-10-16): the separator is only an anchor.
            separator.heightAnchor.constraint(equalToConstant: 0),

            progressLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            density.bind(progressLine.heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.progressThickness },

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            findBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -FindPillMetrics.inset),
            findBar.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: FindPillMetrics.inset),

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
        backButton.action = #selector(goBack)
        forwardButton.action = #selector(goForward)
        installBackForwardMenus()
        reloadButton.target = self
        reloadButton.action = #selector(reloadOrStop)
        addressBar.onEvent = { [weak self] event in self?.omnibarEvent(event) }
        addressBar.pageTitle = { [weak self] in self?.tab.state.title ?? self?.wakingAddress?.title }
        addressBar.onTypedHTTPSUpgrade = { [weak self] url in
            guard let self else { return }
            httpsFallback.expect(url, current: tab.state.loadError)
        }
    }

    private func omnibarEvent(_ event: OmnibarEvent) {
        performOmnibarEnd(event)
        if let onOmnibarEvent { return onOmnibarEvent(event) }
        switch event {
        case .didEndEditing(.commit), .didEndEditing(.open), .didEndEditing(.cancel), .didEndEditing(.keyword): returnFocusToPage()
        case .didBeginEditing, .didEndEditing(.blur), .didEndEditing(.switchToTab): break
        }
    }

    @objc private func goBack() { tab.goBack() }
    @objc private func goForward() { tab.goForward() }
    @objc private func reloadOrStop() { showsStop ? tab.stop() : tab.reload() }

    // MARK: Tab binding

    private func attach(_ tab: any BrowserTab, replacing old: (any BrowserTab)?) {
        observation?.cancel()
        promptObservation?.cancel()
        // Another page in this toolbar: the held address was the old page's.
        if let old, old !== tab { wakingAddress = nil }
        siteZoom.follow(tab)
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
        toolbarButtons.bind(tab)
        addressBar.bindKeywords(of: tab)
        if !findBar.isHidden {
            old?.clearFind()
            findBar.isHidden = true
        }
        observation = ObservationLoop { [weak self] in self?.render() }
        promptObservation = ObservationLoop { [weak self] in
            self?.renderPrompt()
            self?.updateOcclusion()
        }
    }

    /// Permission prompts in the bar; JavaScript dialogs as cmux dialogs on this tab.
    func renderPrompt() { promptDialogs.render(tab.pendingPrompts.first, in: contentContainer, bar: promptBar) }

    private func render() {
        let state = tab.state
        if let http = httpsFallback.observe(state) {
            // task-owner: one load, after this render (never a load inside the observed render).
            Task { @MainActor [weak self] in self?.tab.load(http) }
        }
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward

        let loading = state.showsLoad
        if loading != showsStop {
            showsStop = loading
            reloadButton.setIcon(loading ? .browserToolbarStop : .browserToolbarReload, label: loading ? Strings.stop : Strings.reload)
        }
        updateAddress(for: state)
        updateMachineBadge()
        recordHistory(state)
        reportFinishedLoad(state)
        progressLine.set(progress: state.progress, visible: loading)

        pageStatus.render(state)

        setToolbarHidden(state.isContentFullscreen || isOmnibarHidden)
        updateOcclusion()
        if state.isContentFullscreen != reportedContentFullscreen {
            reportedContentFullscreen = state.isContentFullscreen
            // task-owner: the host's window work runs after this render, outside its observation.
            Task { @MainActor [weak self, on = reportedContentFullscreen] in self?.onContentFullscreenChange?(on) }
        }
    }

    /// A move to a screen with another scale snaps the toolbar gap again.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Every scale-snapped value, not only the row height: the omnibar's top was computed
        // before the view had a window, at the main screen's scale (1 pt off on a 1x display).
        density.reapply()
    }

    public override func layout() {
        applyToolbarLayout()
        super.layout()
        // Auto Layout may defer the address bar's frame until its subtree is
        // laid out. Follow the card only after that frame reflects this pass.
        addressBar.layoutSubtreeIfNeeded()
        addressBar.followLayout()
        updateOcclusion()
        syncPageOverlays()
    }

    /// Child-window pages draw above this view; tell them where the find
    /// bar, prompt bar, and error page cover them (floating cards are on
    /// the overlay host instead, `PageFloatingOverlays`).
    ///
    /// The find and prompt bars are rounded glass: a page that takes rounded
    /// holes (`BrowserRoundedOcclusionHosting`) gets each bar's glass with its
    /// corner radius, so the page shows around the corners instead of a square
    /// of pane ground (Lawrence 2026-10-27, the save-password bar).
    private func updateOcclusion() {
        guard let occluded = tab as? any BrowserOcclusionHosting else { return }
        let bars: [(bar: NSView, glass: OverlaySurfaceView?)] = [(findBar, findBar.glass), (promptBar, promptBar.glass)]
            .filter { !$0.bar.isHidden && $0.bar.superview != nil }
        var squares = pageStatus.shown
        if let rounded = occluded as? any BrowserRoundedOcclusionHosting {
            let holes = bars.map { bar, glass in
                glass.map { CEFClipShape.RoundedRect(rect: $0.convert($0.bounds, to: tab.contentView), radius: $0.cornerRadius) }
                    ?? CEFClipShape.RoundedRect(rect: convert(bar.frame, to: tab.contentView), radius: 0)
            }
            if rounded.roundedOcclusions != holes { rounded.roundedOcclusions = holes }
        } else {
            squares = bars.map(\.bar) + squares
        }
        let rects = squares.map { convert($0.frame, to: tab.contentView) }
        if occluded.occlusionRects != rects { occluded.occlusionRects = rects }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Surface token in an opaque window, clear over a see-through one (windows.md);
    /// the toolbar takes `appearance.surfaces.browserChrome` over that (R55).
    func updateColors() {
        let paints = WindowBackdrop.current(themeTokens).panesPaintBackground
        performWithTheme {
            let surface = paints ? Palette.surfaceBackground.cgColor : nil
            layer?.backgroundColor = surface
            toolbar.layer?.backgroundColor = Palette.surfaceOverride(.browserChrome)?.cgColor ?? surface
            contentContainer.layer?.borderColor = Palette.separator.cgColor
        }
    }
}

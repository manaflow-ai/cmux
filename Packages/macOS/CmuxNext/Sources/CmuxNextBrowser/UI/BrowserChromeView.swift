public import AppKit
public import CmuxNextDesign

/// A browser pane: the toolbar row (a React page, `BrowserToolbarWebView`: back, forward, reload,
/// the omnibox, extension actions, the trailing buttons), a progress line, and the tab's content with
/// find bar, prompt bar, and error overlays. Hides its toolbar while page content is fullscreen.
public final class BrowserChromeView: NSView {
    /// The tab on screen. Assigning swaps the content view in place.
    public var tab: any BrowserTab {
        didSet { attach(tab, replacing: oldValue) }
    }

    /// When true the chrome handles `BrowserChromeCommand.defaultShortcut`
    /// key equivalents itself. Turn off once the App layer routes those
    /// shortcuts through its own action registry.
    public var handlesDefaultShortcuts = true

    /// Design mode, profile, theme, DevTools and More, after the extension actions.
    public let toolbarButtons = BrowserToolbarButtons()

    /// The toolbar row's page: the omnibar and every toolbar control.
    public let addressBar: BrowserToolbarWebView
    /// Page Info, made when it first opens (`pageInfo`), and its command route (the App's registry).
    var pageInfoIfMade: PageInfoController?
    public var pageInfoCommandRouter: ((PageInfoCommand) -> Bool)? { didSet { pageInfoIfMade?.commandRouter = pageInfoCommandRouter } }

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
        get { addressBar.onFocusModeBadgePress }
        set { addressBar.onFocusModeBadgePress = newValue }
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
    /// The find pill and the prompt bar, made when each first shows (#32909).
    private(set) lazy var pageBars = BrowserPageBars(parent: self, page: contentContainer, edge: toolbarEdge, density: density) { [weak self] in
        self?.toolbarPosition ?? .top
    }
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
    var boundState: BrowserChromeTabState?  // the tab state shown now (`bind(_:state:)`); nil: one page only
    var parksLeavingPage = false  // while `bind(_:state:)` switches: the leaving page stays, hidden
    /// Prompts have their own loop: a state change (a title, progress) does not re-render the prompt
    /// bar, and a new prompt does not re-run the rest of the chrome.
    private var promptObservation: ObservationLoop?
    /// Follows the tab's hovered link (`renderLinkStatus`).
    private var linkStatusObservation: ObservationLoop?
    /// The address a page woken from hibernation slept on, shown until the
    /// woken page reports a real one (`holdAddress(whileWaking:)`).
    var wakingAddress: BrowserTabState?
    /// The shown tab's loads (history, finished pages, the https fallback): its own, or the bound tab's (`BrowserPageLoads`).
    var loads = BrowserPageLoads()
    var isToolbarHidden = false
    /// The key-resize hold this chrome follows its pane through (FRAME OWNER S3, `BrowserChromeView+PaneMotion`); nil at rest.
    var paneMotionHold: PaneMotionHold?
    /// The edge the toolbar rows sit on (`browser.toolbarPosition`); the pane sets it.
    public var toolbarPosition: ToolbarPosition = .top {
        didSet { if toolbarPosition != oldValue { applyToolbarPosition() } }
    }
    /// The constraints that put the toolbar rows, page and page bars at the top or bottom.
    let toolbarEdge = ToolbarEdgeConstraints()
    /// The person hid this tab's address bar row (Toggle Omnibar).
    public internal(set) var isOmnibarHidden = false
    let density = DensityBinding()
    /// The pinned extension actions and the Extensions button of the bound tab (the page draws them).
    lazy var extensionActions: ExtensionActions = {
        let actions = ExtensionActions()
        actions.anchor = { [weak self] key in self?.addressBar.anchor(key) }
        actions.onChange = { [weak self] in self?.pushExtensions() }
        // An extension popup opened while the Extensions button is not placed anchors at More.
        actions.menuAnchor = { [weak self] in self?.toolbarButtons.anchor(for: .overflow) }
        return actions
    }()

    /// R101: the toolbar height on this window's pixel grid (else the main screen's).
    var currentToolbarHeight: CGFloat { ToolbarRowMetrics.toolbarHeight(scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    /// Zoom per site (`SiteZoomLevels`).
    let siteZoom = SiteZoomFollower()

    /// Omnibar editing boundaries. When set, the App owns focus: the chrome
    /// only loads a committed URL and never moves focus itself. When nil,
    /// commit and cancel return focus to the page.
    public var onOmnibarEvent: ((OmnibarEvent) -> Void)?

    /// Modified commits (Cmd-Enter) open elsewhere, nil: here; `loadOverride` true: the host served it (`cmux://history`).
    public var onOpenURL: ((URL, OmnibarDisposition) -> Void)?
    public var loadOverride: ((URL) -> Bool)?
    /// A committed URL loads in this tab (a typed navigation).
    public var onTypedCommit: (() -> Void)?

    /// Where finished page loads are recorded (omnibar history suggestions). On a pane's shared chrome this is the
    /// bound tab's (`BrowserChromeTabState.history`); set a tab's hooks on its state, never here.
    public var history: (any BrowserHistoryStore)? {
        get { loads.history }
        set { loads.history = newValue }
    }

    /// Closing the find bar or ending address bar editing hands the keyboard
    /// back to the page. When set, the host does it (a focus coordinator
    /// that also tracks Chromium page windows); else the chrome focuses the
    /// page itself.
    public var onReturnFocusToPage: (() -> Void)?
    public var machineBadge: ((URL?) -> (text: String, help: String)?)? { didSet { updateMachineBadge() } } // remote localhost
    /// Each page that finished loading, once per URL (the App's cookie import offer); the bound tab's, as `history`.
    public var onPageFinished: ((URL) -> Void)? {
        get { loads.onPageFinished }
        set { loads.onPageFinished = newValue }
    }

    public init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine()) {
        self.tab = tab
        addressBar = BrowserToolbarWebView(suggestionEngine: suggestionEngine)
        super.init(frame: .zero)
        wantsLayer = true
        addressBar.setAccessibilityIdentifier(BrowserChromeView.omnibarIdentifier)
        toolbarButtons.toolbarView = addressBar
        buildLayout()
        wireActions()
        attach(tab, replacing: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func showFindBar() {
        let findBar = findBar
        if findBar.isHidden {
            findBar.isHidden = false
            findBar.alphaValue = 0
            Motion.overlays.animate(.fadeIn, in: findBar) { findBar.animator().alphaValue = 1 }
            updateOcclusion()
        }
        findBar.focus()
    }

    public func hideFindBar() {
        guard let findBar = pageBars.findBarIfMade, !findBar.isHidden else { return }
        Motion.overlays.animate(.fadeOut, in: findBar, { findBar.animator().alphaValue = 0 }, completion: {
            findBar.isHidden = true
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
        for view in [toolbar, separator, accessoryBar, contentContainer, progressLine] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        toolbar.wantsLayer = true
        separator.wantsLayer = true
        contentContainer.wantsLayer = true
        contentContainer.layer?.masksToBounds = true

        // The row's page fills the toolbar; it lays out its controls itself (ToolbarRowMetrics). It keeps its
        // height while the row hides (Toggle Omnibar, fullscreen): the row clips it, so no frame relays the page.
        toolbar.addSubview(addressBar)
        toolbar.layer?.masksToBounds = true

        addSubview(contentContainer)
        addSubview(toolbar)
        addSubview(separator)
        installAccessoryBar(below: separator)
        installHeaderBand(beside: accessoryBar)
        addSubview(progressLine)
        pageStatus.install(in: self, over: contentContainer) { [weak self] in self?.tab }

        _ = toolbarHeight  // binds it here, in the same order as before
        // From the top: toolbar, separator, accessory bar, band, page. From the bottom: the same
        // rows mirrored, the page on top (`ToolbarEdgeConstraints`).
        toolbarEdge.top += [
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            addressBar.topAnchor.constraint(equalTo: toolbar.topAnchor),
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progressLine.bottomAnchor.constraint(equalTo: separator.bottomAnchor),
            // The page starts under the header band (empty unless the pane's
            // tab bar sits below the toolbar, R109).
            contentContainer.topAnchor.constraint(equalTo: headerBand.guide.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        toolbarEdge.bottom += [
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor),
            addressBar.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            progressLine.topAnchor.constraint(equalTo: separator.topAnchor),
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: headerBand.guide.topAnchor),
        ]
        toolbarEdge.activate(toolbarPosition)
        // A density or `browser.omnibar.*` change re-lays the row out (the page gets the new metrics).
        density.update { [weak self] in self?.addressBar.setNeedsPush() }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarHeight,
            addressBar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            density.bind(addressBar.heightAnchor.constraint(equalToConstant: 0)) { [weak self] in self?.currentToolbarHeight ?? 0 },

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            // No line between the omnibar and the page (Lawrence 2026-10-16): the separator is only an anchor.
            separator.heightAnchor.constraint(equalToConstant: 0),

            progressLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            density.bind(progressLine.heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.progressThickness },

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        pageBars.onCloseFind = { [weak self] in self?.hideFindBar() }
        density.start()
        updateColors()
    }

    private func wireActions() {
        addressBar.onCommand = { [weak self] command in self?.performToolbarCommand(command) }
        addressBar.onLayout = { [weak self] report in self?.toolbarDidLayOut(report) }
        toolbarButtons.onChange = { [weak self] in self?.pushButtons() }
        addressBar.onPageInfo = { [weak self] in self?.pageInfo.toggle() }
        addressBar.onEvent = { [weak self] event in self?.omnibarEvent(event) }
        addressBar.pageTitle = { [weak self] in self?.tab.state.title ?? self?.wakingAddress?.title }
        addressBar.onTypedHTTPSUpgrade = { [weak self] url in
            guard let self else { return }
            loads.httpsFallback.expect(url, current: tab.state.loadError)
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

    // MARK: Tab binding

    /// Binds `tab` in place of `old`; `tab` again (a tab switch to the same page) re-binds it under the new tab state.
    func attach(_ tab: any BrowserTab, replacing old: (any BrowserTab)?) {
        observation?.cancel()
        promptObservation?.cancel()
        linkStatusObservation?.cancel()
        // Another page in this toolbar: the held address was the old page's (a tab switch put back its own).
        if let old, old !== tab, !parksLeavingPage { wakingAddress = nil }
        siteZoom.follow(tab)
        if boundState == nil { loads.follow(tab) }  // a bound tab's loads follow it (`BrowserChromeTabState.loads`)
        let area = BrowserPageArea(container: contentContainer)
        if let old, old !== tab {
            area.leave(old.contentView, parks: parksLeavingPage)
            // A parked page carries no key-resize hold: the hold's end reaches only the shown page (one chrome per
            // pane), and the line below holds this page again if it shows while the hold still runs.
            (old.contentView as? any BrowserPagePaneMotionHolding)?.holdPage(for: nil)
        }
        pageInfoIfMade?.tabDidChange()
        area.show(tab.contentView)
        // A page that comes in while the chrome follows its pane through a key hold keeps the pane's page size too.
        if let paneMotionHold { (tab.contentView as? any BrowserPagePaneMotionHolding)?.holdPage(for: paneMotionHold) }
        pageBars.findBarIfMade?.tab = tab
        addressBar.allowsChromiumSchemes = tab.engineKind == .cef
        extensionActions.bind(tab)
        toolbarButtons.bind(tab)
        addressBar.bindKeywords(of: tab)
        if let findBar = pageBars.findBarIfMade, !findBar.isHidden {
            old?.clearFind()
            findBar.isHidden = true
        }
        observation = ObservationLoop { [weak self] in self?.render() }
        promptObservation = ObservationLoop { [weak self] in
            self?.renderPrompt()
            self?.updateOcclusion()
        }
        linkStatusObservation = ObservationLoop { [weak self] in self?.renderLinkStatus() }
    }

    /// Permission prompts in the bar; JavaScript dialogs as cmux dialogs on this tab.
    func renderPrompt() { promptDialogs.render(tab.pendingPrompts.first, in: contentContainer, shownBar: pageBars.promptBarIfMade) { [pageBars] in pageBars.promptBar } }

    private func render() {
        let state = tab.state
        let loading = state.showsLoad
        addressBar.navigation = ToolbarNavigation(canGoBack: state.canGoBack, canGoForward: state.canGoForward, loading: loading)
        // The title rides in the state (the chip's drag names the page); a title-only change pushes.
        addressBar.pageTitleChanged(state.title)
        updateAddress(for: state)
        updateMachineBadge()
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
        super.layout()
        // Auto Layout may defer a page bar's glass two levels down on its first show (its hole in the page would be empty).
        for view in pageBars.shown.map(\.bar) { view.layoutSubtreeIfNeeded() }
        // The pane resized or moved the row on screen: an open suggestion card follows it.
        addressBar.followLayout()
        updateOcclusion()
        fitLinkStatus()
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
        let bars = pageBars.shown
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
        performWithTheme {
            // In this view's scope: its workspace's picture decides, not the app's (#28867).
            let paints = WindowBackdrop.current(themeTokens).panesPaintBackground
            let surface = paints ? Palette.surfaceBackground.cgColor : nil
            layer?.backgroundColor = surface
            toolbar.layer?.backgroundColor = Palette.surfaceOverride(.browserChrome)?.cgColor ?? surface
            contentContainer.layer?.borderColor = Palette.separator.cgColor
        }
    }
}

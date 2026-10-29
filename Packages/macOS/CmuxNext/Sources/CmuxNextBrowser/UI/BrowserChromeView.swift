public import AppKit
public import CmuxNextDesign
import CmuxNextIcons
public import CmuxNextWakeups

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
    public var extensionSlot: NSStackView { slot }
    private let slot: ToolbarSlotView
    /// Design mode, profile, theme, DevTools and More, after the extension slot.
    public let toolbarButtons: BrowserToolbarButtonsView

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

    /// The toolbar row; the arrow shows over all of it (`OmnibarPointer`).
    let toolbar: BrowserToolbarRowView
    let separator = NSView()
    /// Holds an optional bar under the toolbar (the bookmarks bar); zero high when empty.
    let accessoryBar = NSView()
    var accessoryHeight: CGFloat = 0
    /// The accessory bar's height in the layout now: 0 while it is hidden (`applyAccessoryHeight`).
    var shownAccessoryHeight: CGFloat = 0
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
    /// Find in page: the bar's state, which the find bar view writes and renders.
    public let find: BrowserFindModel
    let findBar: FindBarView
    let promptBar = PromptBarView()
    private let promptDialogs = BrowserPromptDialogs()
    let pageStatus = PageStatusViews()
    lazy var pageOverlays = PageFloatingOverlays(page: contentContainer)
    /// The app's scheduler, and the tab's node (nil: node-free, as in a debug window or a test).
    let mainWork: MainWorkScheduler, node: VisibilityNode?
    /// The node the chrome's view work waits on (R-appear, R-hide): the tab's, or with no tab node a root
    /// that stays visible, so that work runs at once as before. The address bar and the toolbar buttons
    /// share it.
    let visibilityNode: VisibilityNode
    private var observation: ObservationLoop?
    /// Prompts have their own loop: a title or progress does not re-render the prompt bar, nor a prompt the chrome.
    private var promptObservation: ObservationLoop?
    /// The address a page woken from hibernation slept on, shown until the
    /// woken page reports a real one (`holdAddress(whileWaking:)`).
    var wakingAddress: BrowserTabState?
    /// A typed https upgrade in flight (Chrome's http fallback).
    var httpsFallback = HTTPSUpgradeFallback()
    private var showsStop = false
    var isToolbarHidden = false
    /// Counts toolbar hide and show changes; only the latest one's landing hides the row.
    var toolbarToggles = 0
    /// The frames a toolbar change starts from, until the layout that places the rows at rest.
    var pendingToolbarSlide: ToolbarSlide?
    /// The last toolbar change ran on the render server: a hidden row parks past its edge at its height.
    var toolbarParks = false
    /// Whether toolbar changes move on the render server (`motion.renderServer`, off by default); read
    /// at each change. Off: the rows' frames animate on the main thread as before.
    let rendersMotionOnServer: () -> Bool
    /// Under the page area: the page's background fills a gap the sliding page leaves (Chrome's gutter).
    let pageGutter = NSView()
    /// The edge the toolbar rows sit on (`browser.toolbarPosition`); the pane sets it.
    public var toolbarPosition: ToolbarPosition = .top {
        didSet { if toolbarPosition != oldValue { applyToolbarPosition() } }
    }
    /// The constraints that put the find and prompt bars at the page's edge by the toolbar.
    let toolbarEdge = ToolbarEdgeConstraints()
    /// The person hid this tab's address bar row (Toggle Omnibar).
    public internal(set) var isOmnibarHidden = false
    private let density = DensityBinding()
    lazy var extensionToolbar: ExtensionActionToolbar = {
        let toolbar = ExtensionActionToolbar(slot: extensionSlot, mainWork: mainWork, node: node)
        toolbar.onPinnedCountChange = { [weak self] in self?.applyToolbarLayout() }
        // An extension popup opened while the Extensions button is not placed anchors at More.
        toolbar.menuAnchor = { [weak self] in self?.toolbarButtons.anchor(for: .overflow) }
        return toolbar
    }()

    /// The window's backing scale (else the main screen's): R101 snaps the toolbar's gaps to it.
    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    /// The token sizes the rows lay out with (`applyMetrics`, read again on a density or scale change).
    private var rowMetrics = BrowserChromeRowMetrics(toolbarHeight: 0, progressThickness: 0) {
        didSet { if rowMetrics != oldValue { needsLayout = true } }
    }
    /// The toolbar row's height in the layout: 0 while it is hidden.
    var toolbarRowHeight: CGFloat { isToolbarHidden ? 0 : rowMetrics.toolbarHeight }

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

    /// `mainWork` is the app's one main-thread scheduler; `node` the tab's (`TabContentCache.node(for:)`).
    /// `rendersMotionOnServer`: the app's `motion.renderServer` switch (``MotionBackend``).
    public init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine(), mainWork: MainWorkScheduler,
                node: VisibilityNode?, rendersMotionOnServer: @escaping () -> Bool = { false }) {
        (self.tab, self.mainWork, self.node) = (tab, mainWork, node)
        self.rendersMotionOnServer = rendersMotionOnServer
        visibilityNode = node ?? VisibilityNode(root: "browser.chrome.standalone", own: .visible)
        let find = BrowserFindModel()
        self.find = find
        findBar = FindBarView(model: find)
        let addressBar = AddressBarView(suggestionEngine: suggestionEngine, mainWork: mainWork)
        // Chromium toolbar glyphs: plain arrows, not chevrons.
        let back = ChromeIconButton(icon: .browserToolbarBack, label: Strings.back, action: nil, target: nil, toolbar: true, toolTip: false)
        let forward = ChromeIconButton(icon: .browserToolbarForward, label: Strings.forward, action: nil, target: nil, toolbar: true, toolTip: false)
        let reload = ChromeIconButton(icon: .browserToolbarReload, label: Strings.reload, action: nil, target: nil, toolbar: true, toolTip: false)
        let slot = ToolbarSlotView(), buttons = BrowserToolbarButtonsView()
        self.addressBar = addressBar
        (backButton, forwardButton, reloadButton) = (back, forward, reload)
        (self.slot, toolbarButtons) = (slot, buttons)
        toolbar = BrowserToolbarRowView(navigation: [back, forward, reload], addressBar: addressBar, slot: slot, buttons: buttons)
        super.init(frame: .zero)
        wantsLayer = true
        backButton.setAccessibilityIdentifier(BrowserChromeView.backIdentifier)
        forwardButton.setAccessibilityIdentifier(BrowserChromeView.forwardIdentifier)
        reloadButton.setAccessibilityIdentifier(BrowserChromeView.reloadIdentifier)
        addressBar.setAccessibilityIdentifier(BrowserChromeView.omnibarIdentifier)
        addressBar.visibilityNode = visibilityNode
        toolbarButtons.visibilityNode = visibilityNode
        buildLayout()
        wireActions()
        attach(tab, replacing: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func showFindBar() {
        find.isPresented = true
        if findBar.isHidden {
            findBar.isHidden = false
            findBar.alphaValue = 0
            Motion.overlays.animate(.fadeIn, in: findBar) { self.findBar.animator().alphaValue = 1 }
            updateOcclusion()
        }
        findBar.focus()
    }

    public func hideFindBar() {
        find.isPresented = false
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
        guard handlesDefaultShortcuts, containsFirstResponder, let command = BrowserChromeCommand.matching(event) else {
            return super.performKeyEquivalent(with: event)
        }
        perform(command)
        return true
    }

    // MARK: Layout

    private func buildLayout() {
        for view in [toolbar, separator, contentContainer, pageGutter] { view.wantsLayer = true }
        contentContainer.layer?.masksToBounds = true
        pageGutter.isHidden = true

        extensionSlot.orientation = .horizontal
        extensionSlot.setAccessibilityLabel(Strings.extensions)

        // Frame layout from the top: toolbar, separator, accessory bar, band, page; from the
        // bottom the same rows mirrored, the page on top (`BrowserChromeLayout`, `layout()`).
        addSubview(pageGutter)
        addSubview(contentContainer)
        addSubview(toolbar)
        addSubview(separator)
        addSubview(accessoryBar)
        addSubview(progressLine)
        pageStatus.install(in: self) { [weak self] in self?.tab }
        addSubview(promptBar)
        addSubview(findBar)
        installPageBars()
        toolbar.position = toolbarPosition
        density.update { [weak self] in self?.applyMetrics() }

        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        promptBar.isHidden = true
        density.start(in: self)
        updateColors()
    }

    /// The find and prompt bars float over the page at its edge by the toolbar. They size
    /// themselves with constraints, and follow the framed page area by constraints.
    private func installPageBars() {
        for bar in [findBar, promptBar] as [NSView] { bar.translatesAutoresizingMaskIntoConstraints = false }
        toolbarEdge.top += [
            // The shared find pill sits where every pane's does.
            findBar.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: FindPillMetrics.inset),
            density.bind(promptBar.topAnchor.constraint(equalTo: contentContainer.topAnchor)) { BrowserMetrics.overlayInset },
        ]
        toolbarEdge.bottom += [
            // The page's bars sit by the toolbar, at the page's bottom.
            findBar.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -FindPillMetrics.inset),
            density.bind(promptBar.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)) { -BrowserMetrics.overlayInset },
        ]
        toolbarEdge.activate(toolbarPosition)
        NSLayoutConstraint.activate([
            findBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -FindPillMetrics.inset),
            findBar.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: FindPillMetrics.inset),
            promptBar.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            density.bind(promptBar.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor)) { BrowserMetrics.overlayInset },
        ])
    }

    /// Reads the token sizes (density, `layout.panePadding`, the window's scale) for the rows;
    /// the density binding runs it again when one changes.
    private func applyMetrics() {
        let scale = backingScale
        toolbar.metrics = ToolbarRowLayout.Metrics(
            inset: OmnibarStyle.toolbarInset, barMargin: OmnibarStyle.barMargin, buttonSpacing: OmnibarStyle.buttonSpacing,
            buttonSize: OmnibarStyle.buttonSize, barTop: OmnibarStyle.barTop(scale: scale), barHeight: OmnibarStyle.barHeight
        )
        extensionSlot.spacing = OmnibarStyle.buttonSpacing
        rowMetrics = BrowserChromeRowMetrics(toolbarHeight: OmnibarStyle.toolbarHeight(scale: scale),
                                             progressThickness: BrowserMetrics.progressThickness)
    }

    /// The toolbar row's frame: hidden on the render server, it keeps its height past its edge, so a
    /// hide moves the row and never resizes it.
    private func toolbarFrame(_ rows: BrowserChromeLayout) -> CGRect {
        guard isToolbarHidden, toolbarParks else { return rows.toolbar }
        let height = rowMetrics.toolbarHeight
        return CGRect(x: 0, y: toolbarPosition == .top ? -height : bounds.height, width: bounds.width, height: height)
    }

    /// The rows' frames for the view's size and state now.
    var chromeLayout: BrowserChromeLayout {
        BrowserChromeLayout(BrowserChromeLayout.Input(
            size: bounds.size, position: toolbarPosition, toolbarHeight: toolbarRowHeight, accessoryHeight: shownAccessoryHeight,
            bandHeight: headerBand.height, progressThickness: rowMetrics.progressThickness
        ))
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
        siteZoom.follow(tab, on: mainWork)
        if let old, old !== tab { old.contentView.removeFromSuperview() }
        pageInfo.tabDidChange()
        // The page fills the page area and follows its size (frame layout, no constraints).
        let content = tab.contentView
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = contentContainer.bounds
        contentContainer.addSubview(content)
        findBar.tab = tab
        addressBar.allowsChromiumSchemes = tab.engineKind == .cef
        extensionToolbar.bind(tab)
        toolbarButtons.bind(tab, on: mainWork, node: node)
        addressBar.bindKeywords(of: tab)
        if !findBar.isHidden {
            old?.clearFind()
            findBar.isHidden = true
        }
        // node-free: the render records history, the finished load and the https fallback of background tabs too
        observation = ObservationLoop(owner: "browser.chrome", delivery: .visible(nil), on: mainWork) { [weak self] in self?.render() }
        // node-free: an agent's off-screen render window shows a hidden tab's page with its prompt bar
        promptObservation = ObservationLoop(owner: "browser.chrome.prompts", delivery: .visible(nil), on: mainWork) { [weak self] in
            self?.renderPrompt()
            self?.updateOcclusion()
        }
    }

    /// Permission prompts in the bar; JavaScript dialogs as cmux dialogs on this tab.
    func renderPrompt() { promptDialogs.render(tab.pendingPrompts.first, in: contentContainer, bar: promptBar) }

    private func render() {
        let state = tab.state
        if let http = httpsFallback.observe(state) {
            // One load, after this render (never a load inside the observed render): the rest of the person's
            // typed navigation (Chrome's TypedNavigationUpgradeThrottle falls back the same way).
            // node-free: a background tab's fallback loads too
            mainWork.post(.userBlocking, owner: "browser.chrome.httpsFallback") { [weak self] in self?.tab.load(http) }
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

        pageStatus.render(tab: tab)

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
        let rows = chromeLayout, mapping = chromeFrameMapping
        toolbar.setChromeFrame(mapping.map(toolbarFrame(rows)))
        separator.setChromeFrame(mapping.map(rows.separator))
        accessoryBar.setChromeFrame(mapping.map(rows.accessoryBar))
        contentContainer.setChromeFrame(mapping.map(rows.content))
        pageGutter.setChromeFrame(contentContainer.frame)
        progressLine.setChromeFrame(mapping.map(rows.progressLine))
        accessoryView?.setChromeFrame(accessoryBar.bounds)
        if tab.contentView.superview === contentContainer { tab.contentView.setChromeFrame(contentContainer.bounds) }
        // The page bars follow the page area by constraints; the status views by frame, below.
        promptBar.followRoom()
        super.layout()
        // The row places the address bar in its own layout, which runs after this one.
        // sync-layout: followLayout below reads the address bar's frame from this pass.
        toolbar.layoutSubtreeIfNeeded()
        addressBar.followLayout()
        pageStatus.layout(over: contentContainer.frame)
        updateOcclusion()
        syncPageOverlays()
        reportHeaderBandLayout(mapping.map(rows.band))
        startToolbarSlide()
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

    /// A hidden tab repaints once, when it shows (R-appear).
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visibilityNode.deferAppearance(owner: Self.appearanceKey) { [weak self] in self?.updateColors() }
    }

    /// The ``visibilityNode`` keys of the chrome's deferred repaints.
    static let appearanceKey = "BrowserChromeView.appearance"
    static let shownKey = "BrowserChromeView.shown"

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

import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHistory
import CmuxNextSidebar
import CmuxNextTerminal
import Observation

/// Window content: the sidebar flush on the leading edge (traffic lights sit
/// on its top), or on the trailing edge (`sidebar.side`, R109; the traffic
/// lights then sit over the top-left tab strip), and the workspace layout
/// beside it. `window.titlebar`
/// "minimal" (the default) has no titlebar strip: the layout reaches the
/// window's top edge, the traffic lights sit in the top row (the sidebar
/// header, or with the sidebar hidden the top-left tab strip, which starts
/// after them), and that row's empty space moves the window. "standard"
/// adds a compact titlebar across the content column with the workspace
/// name. Every surface is the one surface token
/// (`Palette.surfaceBackground`), so sidebar, titlebar, tab strip and
/// terminal read as one sheet with no panel edges or seams. In a
/// translucent window that sheet is one material with one theme tint
/// (`backdropView`, the bottom subview) and everything above it is clear.
final class WindowRootView: NSView, WindowSurfacePainting {
    let titlebar = TitlebarView()
    /// The window's one material and tint (`WindowBackdrop`).
    let backdropView = WindowMaterialView(frame: .zero)
    /// Whether Reduce Transparency is on (tests pin it; the host setting
    /// differs between machines). Internal, not private: the painting itself
    /// is in `WindowRootView+Surface`.
    let reduceTransparency: @MainActor () -> Bool
    /// Sets the window's behind-window blur radius (tests record it).
    /// Internal for the same reason as `reduceTransparency`.
    let applyWindowBlur: @MainActor (NSWindow, Int) -> Void
    /// The workspace content: the curved main pane, inset and rounded
    /// (cx-rkgu), or edge to edge.
    let contentHost = MainPaneCardView(frame: .zero)
    /// The shade over the chrome around the curved main pane.
    let mainPaneShade = MainPaneChromeShadeView(frame: .zero)
    /// The content host's top and bottom pins (the side pins are in
    /// `sidePins`); their constants are the main pane's gutter.
    var mainPaneEdges: [NSLayoutConstraint] = []
    private var mainPaneObservation: Task<Void, Never>?
    let sidebar: SidebarContainerView
    /// The edge the sidebar sits on (`sidebar.side`, R109).
    var sidebarSide: SidebarSide = .left {
        didSet { if sidebarSide != oldValue { applySidebarSide() } }
    }
    /// The sidebar, content and title pins of each side (`applySidebarSide`).
    var sidePins: [SidebarSide: [NSLayoutConstraint]] = [:]
    private var placementObservation: Task<Void, Never>?
    private var titleHeight: NSLayoutConstraint?
    private var tokenObservation: Task<Void, Never>?
    private var displayOptionsObserver: MainActorObservation?
    private(set) weak var content: NSView?
    /// Empties AppKit's titlebar drag region: the window moves only through
    /// `TitlebarDragPolicy` (`ShellWindow.sendEvent`).
    let titlebarBandBlocker = TitlebarDragBlocker(frame: .zero)
    /// The top-left toolbar band (R68): the static sidebar toggle, above
    /// the sidebar so it takes clicks while the sidebar animates.
    let toolbarBand = TitlebarToolbarBand(frame: .zero)
    /// The top row the title bar buttons reveal over (R83): full width,
    /// takes no clicks.
    let titlebarRevealRegion = PassThroughView(frame: .zero)
    /// A patch under the traffic lights that fades in with the buttons. It
    /// is a theme fill, not a second glass material: the window keeps its
    /// one root material (WindowRootMaterialTests).
    let trafficLightsGlass = TrafficLightsPatch(frame: .zero)
    /// Back, Forward and the glass patch: hidden until the top row or the
    /// sidebar is hovered (`window.titlebarButtons`). The sidebar toggle
    /// always shows.
    private(set) lazy var titlebarReveal = HoverReveal(region: titlebarRevealRegion)
    /// Held while the pointer is over the sidebar (its chrome reveal).
    var sidebarHoverHold: HoverReveal.Hold?
    /// The sidebar is hidden (WindowController follows the sidebar model).
    /// The toggle's glyph follows; the band's width follows the sidebar's
    /// on-screen width instead (`toolbarBandPresence`).
    var sidebarHidden = false {
        didSet {
            toolbarBand.showSidebarState(hidden: sidebarHidden)
            collapsedBand.setSidebarHidden(sidebarHidden)
        }
    }
    /// Opens the collapsed band while the top-left corner is hovered.
    let collapsedBand: CollapsedBandReveal
    /// The right sidebar (`WindowController+RightSidebar`), on the edge
    /// opposite the sidebar; nil until it first shows.
    var rightPanel: RightSidebarView? {
        didSet {
            guard rightPanel !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let rightPanel { addSubview(rightPanel, positioned: .below, relativeTo: titlebarBandBlocker) }
            needsLayout = true
        }
    }
    /// A fullscreen page has the whole window (`WindowRootView+MainPane`): the content host
    /// fills it, and the chrome around it hides.
    var presentsPage = false {
        didSet { if presentsPage != oldValue { applyPagePresentation() } }
    }
    /// The content host's pins to the window's edges while `presentsPage`.
    lazy var pagePresentationPins: [NSLayoutConstraint] = [
        contentHost.leadingAnchor.constraint(equalTo: leadingAnchor), contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
        contentHost.topAnchor.constraint(equalTo: topAnchor), contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]
    /// The chrome views `presentsPage` hid.
    var pagePresentationHidden: [NSView] = []
    /// The right sidebar's on-screen width (0 while hidden): the main pane
    /// is inset by it (`applyMainPane`).
    var rightPanelWidth: CGFloat = 0 {
        didSet {
            guard rightPanelWidth != oldValue else { return }
            applyMainPane()
            layoutSubtreeIfNeeded()
        }
    }

    /// - Parameter sidebar: The window's sidebar.
    /// - Parameter reduceTransparency: The user's Reduce Transparency
    ///   setting, read on every theme and display-options change.
    /// - Parameter applyWindowBlur: Sets the window's behind-window blur
    ///   radius (the backdrop's ``WindowBackdrop/windowBlurRadius``).
    /// - Parameter revealClock: Times the collapsed band's close delay.
    init(sidebar: SidebarContainerView,
         reduceTransparency: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
         applyWindowBlur: @escaping @MainActor (NSWindow, Int) -> Void = { $0.setBackgroundBlurRadius($1) },
         revealClock: any Clock<Duration> = ContinuousClock()) {
        self.sidebar = sidebar
        collapsedBand = CollapsedBandReveal(clock: revealClock)
        self.reduceTransparency = reduceTransparency
        self.applyWindowBlur = applyWindowBlur
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        wantsLayer = true
        backdropView.frame = bounds
        backdropView.autoresizingMask = [.width, .height]
        addSubview(backdropView)
        mainPaneShade.frame = bounds
        mainPaneShade.autoresizingMask = [.width, .height]
        addSubview(mainPaneShade)
        for view in [contentHost, titlebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(sidebar)
        addSubview(titlebarBandBlocker)
        addSubview(trafficLightsGlass)
        addSubview(toolbarBand)
        addSubview(titlebarRevealRegion)
        let titleHeight = titlebar.heightAnchor.constraint(equalToConstant: 0)
        mainPaneEdges = [contentHost.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
                         contentHost.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            titlebar.topAnchor.constraint(equalTo: topAnchor),
            titleHeight,
            // When the sidebar hides, the title stops clear of the traffic
            // lights while the content below reaches the window edge.
            titlebar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.trafficLightInset),
        ] + mainPaneEdges)
        // The first window opens on the configured side (no move after).
        sidebarSide = DesignSettings.shared.sidebarSide
        sidebar.side = sidebarSide
        sidebar.sidebarView.spacesPosition = DesignSettings.shared.spacesPosition
        sidebar.sidebarView.spacesVisibility = DesignSettings.shared.spacesVisibility
        sidePins = SidebarSide.pins(sidebar: sidebar, content: contentHost, title: titlebar, in: self)
        NSLayoutConstraint.activate(sidePins[sidebarSide] ?? [])
        self.titleHeight = titleHeight
        applyTokens()
        setUpTitlebarReveal()
        setUpCollapsedBandReveal()
        tokenObservation = Task { [weak self] in
            for await _ in ObservationStream({ [Metrics.titlebarHeight, Metrics.tabStripHeight, DesignSettings.shared.titlebar == .minimal ? 1 : 0,
                                           DesignSettings.shared.titlebarButtons == .hover ? 1 : 0] }) {
                self?.applyTokens()
                self?.applyTitlebarButtonsMode()
            }
        }
        placementObservation = observePlacement()
        contentHost.onFrameChange = { [weak self] in self?.updateMainPaneShade() }
        wireContentAreaMotion()
        applyMainPane()
        mainPaneObservation = observeMainPane()
        // queue: .main: the workspace center may post off main; a selector
        // into this main-actor view trapped there.
        displayOptionsObserver = MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.themeDidChange()
        }
        themeDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            tokenObservation?.cancel()
            placementObservation?.cancel()
            mainPaneObservation?.cancel()
        }
    }

    var titlebarStyle: TitlebarStyle { DesignSettings.shared.titlebar }

    /// Minimal: no strip, and the sidebar header is as tall as the tab
    /// strip, so the list starts level with the panes' content.
    func applyTokens() {
        let minimal = titlebarStyle == .minimal
        titleHeight?.constant = minimal ? 0 : Metrics.titlebarHeight
        titlebar.isHidden = minimal || presentsPage
        sidebar.sidebarView.titlebarHeightOverride = minimal ? Metrics.tabStripHeight : Metrics.titlebarHeight
        needsLayout = true
    }

    /// A view shown in the top row after the traffic lights while
    /// `showsTitlebarBadge` (the incognito badge when the sidebar, whose
    /// header shows it otherwise, is hidden). Strips under it start after it
    /// (`TitlebarAccessoryHosting`).
    var titlebarBadge: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let titlebarBadge {
                titlebarBadge.translatesAutoresizingMaskIntoConstraints = true
                addSubview(titlebarBadge, positioned: .above, relativeTo: nil)
            }
            needsLayout = true
        }
    }

    var showsTitlebarBadge = false {
        didSet { if oldValue != showsTitlebarBadge { needsLayout = true } }
    }
    /// The host pressure indicator after the band and the badge (`layoutTitlebarAccessories`).
    var hostPressureIndicator: NSView? { didSet { oldValue?.removeFromSuperview(); hostPressureIndicator.map { addSubview($0, positioned: .above, relativeTo: nil) }; needsLayout = true } }

    var onHintGeometryChange: (() -> Void)?
    /// Called from layout when the band's presence changed, so strips under
    /// the top row recompute their inset in the same layout pass.
    var onToolbarBandPresenceChange: (() -> Void)?

    /// Work after the window's layout pass (`ShellWindow.layoutIfNeeded`),
    /// when every frame is final: the agent cursor goes back on top after a
    /// reorder that added no view (no add hook ran), and the sidebar stays
    /// above Chromium pages and pane overlays (R126) as an occluder of the
    /// window's overlay host. The sidebar's resize band gets a catcher panel
    /// above pages, like a pane divider's hit area.
    func windowDidLayout() {
        // Before the guard: the band's catcher needs no overlay host.
        (window as? ShellWindow)?.overlayLayer.setSidebarResizeBand(sidebar.resizeBandInWindow)
        guard let window, let host = WindowOverlayHost.existingHost(for: window) else { return }
        host.repairAgentCursorOrder()
        let shows = sidebar.frame.width > 0.5 && !sidebar.isHidden
        host.setOccluder(id: "sidebar", rect: shows ? sidebar.convert(sidebar.bounds, to: nil) : nil)
    }

    override func layout() {
        defer { onHintGeometryChange?() }
        super.layout()
        // Inside the window's layout pass the cursor order and the sidebar
        // occluder wait for its end (`windowDidLayout`): both change other
        // windows (overlay panel, pages) or this view's subviews.
        if (window as? ShellWindow)?.isInLayoutPass != true { windowDidLayout() }
        TitlebarDragPolicy.layoutBandBlocker(titlebarBandBlocker, in: self)
        updateMainPaneTopInset()
        // Every frame is final here: the shade follows the card even when the
        // shade's own autoresizing landed after the card's frame change.
        updateMainPaneShade()
        // The band starts after the traffic lights (which never move) and is
        // as wide as the sidebar's on-screen share: 0 wide, with no gap
        // after the lights, while the sidebar is hidden (cx-uxdr).
        let rowHeight = titlebarStyle == .minimal ? Metrics.tabStripHeight : Metrics.titlebarHeight
        var lightsMaxX: CGFloat = 0
        var midY = bounds.maxY - rowHeight / 2
        if let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            (window as? ShellWindow)?.noteTrafficLights(lights)
            let local = convert(lights, from: nil)
            lightsMaxX = local.maxX
            midY = local.midY
        }
        let presence = toolbarBandPresence
        let bandHeight = TitlebarBandButton.side
        let bandWidth = (TitlebarToolbarBand.width * presence * 2).rounded() / 2
        let presenceChanged = toolbarBand.presence != presence
        toolbarBand.presence = presence
        toolbarBand.frame = CGRect(x: lightsMaxX + Metrics.space3 * presence, y: (midY - bandHeight / 2).rounded(),
                                   width: bandWidth, height: bandHeight)
        // A right sidebar's header is clear of the traffic lights and the band.
        // The reserve is the full band, so the header does not reflow while
        // the sidebar slides out.
        let fullBandMaxX = lightsMaxX + Metrics.space3 + TitlebarToolbarBand.width
        sidebar.sidebarView.headerHasWindowControls = sidebarSide == .left
        sidebar.sidebarView.titlebarLeadingReserve = sidebarSide == .left ? fullBandMaxX + Metrics.space2 : Metrics.space3
        if presenceChanged { onToolbarBandPresenceChange?() }
        layoutTitlebarReveal(rowHeight: rowHeight, fullBandMaxX: fullBandMaxX)
        layoutRightPanel(rowHeight: rowHeight)
        layoutTitlebarAccessories(midY: midY)
    }

    /// Called after `show(_:)` swaps the content (a top page or a workspace).
    var onContentChange: (() -> Void)?

    /// Keeps the outgoing content until an unpainted top page paints.
    let paintHold = PanePaintHold(owner: "window.paint-hold")

    /// Replaces the shown content. A workspace's view stays in the window, hidden (its controller
    /// keeps it mounted and removes it at teardown), so a switch moves no view out of the window or
    /// back: no window re-entry, no observer churn (I6). Other content leaves. A top page that has not
    /// painted (a transparent web view) shows once it paints; the outgoing content stays until
    /// then, as in a pane (no-flicker audit).
    func show(_ view: NSView) {
        guard content !== view else { return }
        let previous = content
        // While an earlier swap waits, the view on screen is the one it keeps.
        let outgoing = paintHold.kept ?? previous
        let holds = PanePaintHold.holds(view, replacing: outgoing)
        content = view
        if holds, paintHold.kept != nil {
            // The page that never showed leaves; the kept view stays for this hold.
            paintHold.handOff(remove: withdraw)
        } else {
            // The earlier swap ends now; a view it kept that is shown again
            // stays (no detach of its panes).
            paintHold.end()
            if !holds {
                for case let old? in [previous, outgoing] where old !== view { withdraw(old) }
            }
        }
        // Mid-slide the content keeps the slide's one width (`MainPaneCardView.contentHold`).
        let frame = contentHost.heldContentFrame ?? contentHost.bounds
        if view.superview !== contentHost {
            view.frame = frame
            contentHost.addSubview(view)
        } else if view.frame != frame {
            view.frame = frame
        }
        view.autoresizingMask = [.width, .height]
        // Unparked while still hidden, so the subtree hears only the unhide.
        (view as? WorkspaceContentView)?.setParked(false)
        view.isHidden = false
        let paneCards = (view as? WorkspaceContentView)?.layoutView as? any PaneCardSource
        if holds, let outgoing {
            paintHold.begin(outgoing: outgoing, incoming: view, in: contentHost, release: { [weak self] outgoing in
                guard let self, outgoing.superview === contentHost, outgoing !== content else { return }
                withdraw(outgoing)
            }, ended: { [weak self, weak view] in
                // The shade cuts out the panes on screen: the incoming workspace's once it shows.
                guard let self, let view, view === content else { return }
                mainPaneShade.paneCards = paneCards
            })
        } else {
            mainPaneShade.paneCards = paneCards
        }
        // A workspace's theme scope inherits this window's room theme.
        view.reparentRootedThemeScope()
        onContentChange?()
    }

    /// Takes `view` off screen: a workspace hides in place, sized only when shown again (no layout
    /// while hidden); the keyboard leaves it (the focus model re-applies its target, as when a view
    /// leaves the window). Other content leaves the window.
    private func withdraw(_ view: NSView) {
        guard view is WorkspaceContentView, view.superview === contentHost else { return view.removeFromSuperview() }
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view),
           !window.makeFirstResponder(nil) {
            // A field editor that refuses to resign while it validates: end the edit, then resign.
            window.endEditing(for: nil)
            window.makeFirstResponder(nil)
        }
        view.isHidden = true
        // Parked once hidden: the hidden subtree hears nothing more.
        (view as? WorkspaceContentView)?.setParked(true)
        view.autoresizingMask = []
    }

    /// Paints only this view. The window's opacity and background are set by
    /// `applyBackdrop(to:)` before the window installs this view: AppKit
    /// calls this hook from inside `NSWindow.contentView`'s setter, and a
    /// window background change there drops the theme frame's backdrop view
    /// that the setter places the content relative to, so the content lands
    /// above the titlebar and its opaque layer hides the traffic lights
    /// (nxdog12).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paintBackground()
    }

    /// A later subview must not cover the window's agent cursor while it
    /// lives here (the overlay panel is detached): the host raises it again.
    /// The positioned add places the view after `didAddSubview`, so it
    /// raises once more when the add returns.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let window { WindowOverlayHost.existingHost(for: window)?.contentViewDidAddSubview(subview) }
    }

    /// A `subviews =` assignment adds through no hook above.
    override var subviews: [NSView] {
        didSet { if let window { WindowOverlayHost.existingHost(for: window)?.repairAgentCursorOrder() } }
    }

    override func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode, relativeTo otherView: NSView?) {
        super.addSubview(view, positioned: place, relativeTo: otherView)
        if let window { WindowOverlayHost.existingHost(for: window)?.contentViewDidAddSubview(view) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeDidChange()
    }

    /// Surface color plus window opacity: a translucent background
    /// (`background-opacity`, `background-blur`, or cmux.json's
    /// `appearance.backgroundOpacity` and `appearance.backgroundBlur`)
    /// makes the whole window one material with the theme tint over it
    /// (`WindowBackdrop`). Re-run on theme and Reduce Transparency changes.
    func themeDidChange() {
        paintBackground()
        updateMainPaneShade()
        if let window { applyBackdrop(to: window) }
    }

    // The window's own background, opacity and blur are in
    // `WindowRootView+Surface`.
}

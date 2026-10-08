import AppKit
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
    /// differs between machines).
    private let reduceTransparency: @MainActor () -> Bool
    /// Sets the window's behind-window blur radius (tests record it).
    private let applyWindowBlur: @MainActor (NSWindow, Int) -> Void
    let contentHost = NSView()
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
    /// The traffic lights and the toggle stay shown either way, so the
    /// toggle is one fixed target (Leo, T3 Code ref); its glyph follows.
    var sidebarHidden = false {
        didSet { toolbarBand.showSidebarState(hidden: sidebarHidden) }
    }

    /// - Parameter sidebar: The window's sidebar.
    /// - Parameter reduceTransparency: The user's Reduce Transparency
    ///   setting, read on every theme and display-options change.
    /// - Parameter applyWindowBlur: Sets the window's behind-window blur
    ///   radius (the backdrop's ``WindowBackdrop/windowBlurRadius``).
    init(sidebar: SidebarContainerView,
         reduceTransparency: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
         applyWindowBlur: @escaping @MainActor (NSWindow, Int) -> Void = { $0.setBackgroundBlurRadius($1) }) {
        self.sidebar = sidebar
        self.reduceTransparency = reduceTransparency
        self.applyWindowBlur = applyWindowBlur
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        wantsLayer = true
        backdropView.frame = bounds
        backdropView.autoresizingMask = [.width, .height]
        addSubview(backdropView)
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
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            titlebar.topAnchor.constraint(equalTo: topAnchor),
            titleHeight,
            // When the sidebar hides, the title stops clear of the traffic
            // lights while the content below reaches the window edge.
            titlebar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.trafficLightInset),
            contentHost.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // The first window opens on the configured side (no move after).
        sidebarSide = DesignSettings.shared.sidebarSide
        sidebar.side = sidebarSide
        sidebar.sidebarView.spacesPosition = DesignSettings.shared.spacesPosition
        sidePins = Self.sidePins(sidebar: sidebar, content: contentHost, title: titlebar, in: self)
        NSLayoutConstraint.activate(sidePins[sidebarSide] ?? [])
        self.titleHeight = titleHeight
        applyTokens()
        setUpTitlebarReveal()
        tokenObservation = Task { [weak self] in
            for await _ in Observations({ [Metrics.titlebarHeight, Metrics.tabStripHeight, DesignSettings.shared.titlebar == .minimal ? 1 : 0,
                                           DesignSettings.shared.titlebarButtons == .hover ? 1 : 0] }) {
                self?.applyTokens()
                self?.applyTitlebarButtonsMode()
            }
        }
        placementObservation = observePlacement()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        themeDidChange()
    }

    @objc private func displayOptionsChanged() {
        themeDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        tokenObservation?.cancel()
        placementObservation?.cancel()
    }

    var titlebarStyle: TitlebarStyle { DesignSettings.shared.titlebar }

    /// Minimal: no strip, and the sidebar header is as tall as the tab
    /// strip, so the list starts level with the panes' content.
    private func applyTokens() {
        let minimal = titlebarStyle == .minimal
        titleHeight?.constant = minimal ? 0 : Metrics.titlebarHeight
        titlebar.isHidden = minimal
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

    /// The static sidebar toggle (R68).
    var sidebarToggleButton: NSButton? { toolbarBand.sidebarToggle }
    /// The toggle's frame in window coordinates.
    var sidebarToggleFrame: CGRect? {
        let toggle = toolbarBand.sidebarToggle
        return toggle.convert(toggle.bounds, to: nil)
    }
    /// The window's close, minimize and zoom buttons.
    var trafficLightButtons: [NSView] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }
    /// A click on the toggle (tests).
    func pressSidebarToggle() { toolbarBand.toggle() }
    /// A history button's frame in window coordinates (R69).
    func historyButtonFrame(_ direction: LocationTrailDirection) -> CGRect? {
        let button = toolbarBand.historyButton(direction)
        return button.convert(button.bounds, to: nil)
    }
    /// Whether a history button is enabled (tests).
    func historyButtonEnabled(_ direction: LocationTrailDirection) -> Bool { toolbarBand.historyButton(direction).isEnabled }
    /// A click on a history button (tests).
    func pressHistoryButton(_ direction: LocationTrailDirection) { toolbarBand.onHistory?(direction) }

    /// The badge's frame in window coordinates while it shows.
    var titlebarBadgeFrame: CGRect? {
        guard let badge = titlebarBadge, !badge.isHidden else { return nil }
        return badge.convert(badge.bounds, to: nil)
    }

    /// What strips under the top row keep clear (window coordinates): the
    /// toolbar band and, while it shows, the badge after it.
    var titlebarAccessoryFrame: CGRect {
        let band = toolbarBand.convert(toolbarBand.bounds, to: nil)
        return titlebarBadgeFrame.map { band.union($0) } ?? band
    }

    var onHintGeometryChange: (() -> Void)?

    override func layout() {
        defer { onHintGeometryChange?() }
        super.layout()
        // A reorder that added no view passed no add hook: the agent cursor goes back on top.
        if let window { WindowOverlayHost.existingHost(for: window)?.repairAgentCursorOrder() }
        // The sidebar stays above Chromium pages and pane overlays (R126): an occluder of the window's overlay host.
        if let window {
            let shows = sidebar.frame.width > 0.5 && !sidebar.isHidden
            WindowOverlayHost.existingHost(for: window)?.setOccluder(id: "sidebar", rect: shows ? sidebar.convert(sidebar.bounds, to: nil) : nil)
        }
        TitlebarDragPolicy.layoutBandBlocker(titlebarBandBlocker, in: self)
        // The band depends only on the window's traffic lights and top row,
        // never on the sidebar, so the toggle keeps one frame (R68).
        let rowHeight = titlebarStyle == .minimal ? Metrics.tabStripHeight : Metrics.titlebarHeight
        var x = Metrics.space3
        var midY = bounds.maxY - rowHeight / 2
        if let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            let local = convert(lights, from: nil)
            x = local.maxX + Metrics.space3
            midY = local.midY
        }
        let bandHeight = TitlebarBandButton.side
        toolbarBand.frame = CGRect(x: x, y: (midY - bandHeight / 2).rounded(), width: TitlebarToolbarBand.width, height: bandHeight)
        // A right sidebar's header is clear of the traffic lights and the band.
        sidebar.sidebarView.headerHasWindowControls = sidebarSide == .left
        sidebar.sidebarView.titlebarLeadingReserve = sidebarSide == .left ? toolbarBand.frame.maxX + Metrics.space2 : Metrics.space3
        layoutTitlebarReveal(rowHeight: rowHeight)
        guard let badge = titlebarBadge else { return }
        badge.isHidden = !showsTitlebarBadge
        guard showsTitlebarBadge else { return }
        let size = badge.fittingSize
        badge.frame = CGRect(x: toolbarBand.frame.maxX + Metrics.space2, y: (midY - size.height / 2).rounded(),
                             width: size.width, height: size.height)
    }

    /// Called after `show(_:)` swaps the content (a top page or a workspace).
    var onContentChange: (() -> Void)?

    /// Replaces the workspace layout view.
    func show(_ view: NSView) {
        guard content !== view else { return }
        content?.removeFromSuperview()
        view.frame = contentHost.bounds
        view.autoresizingMask = [.width, .height]
        contentHost.addSubview(view)
        content = view
        // A workspace's theme scope inherits this window's room theme.
        view.reparentRootedThemeScope()
        onContentChange?()
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
        if let window { applyBackdrop(to: window) }
    }

    /// The backdrop this view's theme and the Reduce Transparency setting
    /// describe.
    var backdrop: WindowBackdrop {
        WindowBackdrop(themeTokens, reduceTransparency: reduceTransparency(), art: themeScope.backdropArt,
                       selection: themeScope.backdropSelection, tuning: themeScope.appearanceTuning)
    }

    /// An opaque window paints the solid background on this layer. Over a
    /// material the layer stays clear and the backdrop view's tint is the
    /// one sheet; a frosted window's blur is the window's CGS radius
    /// (`applyBackdrop(to:)`).
    private func paintBackground() {
        let backdrop = self.backdrop
        performWithTheme { paintBackdropSheet(backdrop, surface: Palette.surfaceBackground, backdropView: backdropView) }
    }

    /// `NSWindow.install(kind:content:scope:)`: the backdrop before the
    /// content view goes in.
    func paintWindowSurface(of window: NSWindow) {
        applyBackdrop(to: window)
    }

    /// Sets `window`'s opacity, background and blur radius for this view's
    /// theme.
    /// Values that already match are not written again, so a repeat call
    /// (an appearance change while the window installs this view) never
    /// touches the theme frame.
    func applyBackdrop(to window: NSWindow) {
        window.applyBackdrop(backdrop, surface: performWithTheme { Palette.surfaceBackground }, applyBlur: applyWindowBlur)
    }
}

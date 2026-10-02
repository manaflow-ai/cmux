import AppKit
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTerminal
import Observation

/// Window content: the sidebar flush on the leading edge (traffic lights sit
/// on its top) and the workspace layout beside it. `window.titlebar`
/// "minimal" (the default) has no titlebar strip: the layout reaches the
/// window's top edge, the traffic lights sit in the top row (the sidebar
/// header, or with the sidebar hidden the top-left tab strip, which starts
/// after them), and that row's empty space moves the window. "standard"
/// adds a compact titlebar across the content column with the workspace
/// name. Every surface is the terminal background
/// (`Palette.windowBackground`), so sidebar, titlebar, tab strip and
/// terminal read as one sheet with no panel edges or seams. In a
/// translucent window that sheet is one material with one theme tint
/// (`backdropView`, the bottom subview) and everything above it is clear.
/// `window.rail` moves the sidebar's sticky sections into an icon rail
/// (`WindowRail`) before the sidebar or between the sidebar and the
/// content column.
final class WindowRootView: NSView {
    let titlebar = TitlebarView()
    /// The window's one material and tint (`WindowBackdrop`).
    let backdropView = WindowMaterialView(frame: .zero)
    /// Whether Reduce Transparency is on (tests pin it; the host setting
    /// differs between machines).
    private let reduceTransparency: @MainActor () -> Bool
    /// Sets the window's behind-window blur radius (tests record it).
    private let applyWindowBlur: @MainActor (NSWindow) -> Void
    let contentHost = NSView()
    private let sidebar: SidebarContainerView
    let rail: WindowRailView
    private var titleHeight: NSLayoutConstraint?
    /// The horizontal chain (rail, sidebar, content column) for the current `window.rail`.
    private var placementConstraints: [NSLayoutConstraint] = []
    private var tokenObservation: Task<Void, Never>?
    private var railObservation: Task<Void, Never>?
    private(set) weak var content: NSView?
    /// Empties AppKit's titlebar drag region: the window moves only through
    /// `TitlebarDragPolicy` (`ShellWindow.sendEvent`).
    let titlebarBandBlocker = TitlebarDragBlocker(frame: .zero)

    /// - Parameter sidebar: The window's sidebar.
    /// - Parameter rail: The window's icon rail.
    /// - Parameter reduceTransparency: The user's Reduce Transparency
    ///   setting, read on every theme and display-options change.
    /// - Parameter applyWindowBlur: Sets the window's behind-window blur
    ///   radius from the Ghostty config.
    init(sidebar: SidebarContainerView, rail: WindowRailView,
         reduceTransparency: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
         applyWindowBlur: @escaping @MainActor (NSWindow) -> Void = { _ in }) {
        self.sidebar = sidebar
        self.rail = rail
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
        let titleHeight = titlebar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            titlebar.topAnchor.constraint(equalTo: topAnchor),
            titlebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleHeight,
            // When the sidebar hides, the title stops clear of the traffic
            // lights while the content below reaches the window edge.
            titlebar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.trafficLightInset),
            contentHost.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.titleHeight = titleHeight
        applyRail()
        applyTokens()
        tokenObservation = Task { [weak self] in
            for await _ in Observations({ [Metrics.titlebarHeight, Metrics.tabStripHeight, DesignSettings.shared.titlebar == .minimal ? 1 : 0] }) {
                self?.applyTokens()
            }
        }
        railObservation = Task { [weak self] in
            for await _ in Observations({ DesignSettings.shared.rail }) {
                self?.applyRail()
            }
        }
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
        railObservation?.cancel()
    }

    var titlebarStyle: TitlebarStyle { DesignSettings.shared.titlebar }

    /// Minimal: no strip, and the sidebar header is as tall as the tab
    /// strip, so the list starts level with the panes' content.
    private func applyTokens() {
        let minimal = titlebarStyle == .minimal
        titleHeight?.constant = minimal ? 0 : Metrics.titlebarHeight
        titlebar.isHidden = minimal
        sidebar.sidebarView.titlebarHeightOverride = minimal ? Metrics.tabStripHeight : Metrics.titlebarHeight
        rail.topInset = minimal ? Metrics.tabStripHeight : Metrics.titlebarHeight
        needsLayout = true
    }

    /// Builds the horizontal chain for `window.rail`: "off" keeps the rail
    /// out of the window (the layout before the rail existed), "leading"
    /// puts it at the window's leading edge with the sidebar after it,
    /// "afterSidebar" between the sidebar and the content column. The
    /// titlebar strip and the content column follow whichever comes last.
    func applyRail() {
        NSLayoutConstraint.deactivate(placementConstraints)
        let placement = DesignSettings.shared.rail
        if placement == .off {
            rail.removeFromSuperview()
        } else if rail.superview !== self {
            // Under the sidebar, so its resize handle keeps the shared edge.
            addSubview(rail, positioned: .below, relativeTo: sidebar)
        }
        var constraints: [NSLayoutConstraint] = []
        let column: NSLayoutXAxisAnchor
        switch placement {
        case .off:
            constraints.append(sidebar.leadingAnchor.constraint(equalTo: leadingAnchor))
            column = sidebar.trailingAnchor
        case .leading:
            constraints += [rail.leadingAnchor.constraint(equalTo: leadingAnchor), sidebar.leadingAnchor.constraint(equalTo: rail.trailingAnchor)]
            column = sidebar.trailingAnchor
        case .afterSidebar:
            constraints += [sidebar.leadingAnchor.constraint(equalTo: leadingAnchor), rail.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)]
            column = rail.trailingAnchor
        }
        if placement != .off {
            constraints += [
                rail.topAnchor.constraint(equalTo: topAnchor),
                rail.bottomAnchor.constraint(equalTo: bottomAnchor),
                rail.widthAnchor.constraint(equalToConstant: WindowRail.width),
            ]
        }
        // Below required, so it yields to the traffic-light inset.
        let titleFollowsColumn = titlebar.leadingAnchor.constraint(equalTo: column)
        titleFollowsColumn.priority = .required - 1
        constraints += [titleFollowsColumn, contentHost.leadingAnchor.constraint(equalTo: column)]
        NSLayoutConstraint.activate(constraints)
        placementConstraints = constraints
        // The sidebar shows its sticky sections only without the rail.
        sidebar.sidebarView.needsLayout = true
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

    /// The badge's frame in window coordinates while it shows.
    var titlebarBadgeFrame: CGRect? {
        guard let badge = titlebarBadge, !badge.isHidden else { return nil }
        return badge.convert(badge.bounds, to: nil)
    }

    override func layout() {
        super.layout()
        TitlebarDragPolicy.layoutBandBlocker(titlebarBandBlocker, in: self)
        guard let badge = titlebarBadge else { return }
        badge.isHidden = !showsTitlebarBadge
        guard showsTitlebarBadge else { return }
        let size = badge.fittingSize
        let rowHeight = titlebarStyle == .minimal ? Metrics.tabStripHeight : Metrics.titlebarHeight
        var x = Metrics.space3
        var midY = bounds.maxY - rowHeight / 2
        if let window, let lights = WindowTitlebar.trafficLightsFrame(in: window) {
            let local = convert(lights, from: nil)
            x = local.maxX + Metrics.space3
            midY = local.midY
        }
        badge.frame = CGRect(x: x, y: (midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

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
        WindowBackdrop(themeTokens, reduceTransparency: reduceTransparency())
    }

    /// An opaque window paints the solid background on this layer. Over a
    /// material the layer stays clear and the backdrop view's tint is the
    /// one sheet. No CGS blur is applied: the material view blurs itself.
    private func paintBackground() {
        let backdrop = self.backdrop
        performWithTheme {
            let background = Palette.windowBackground
            layer?.backgroundColor = backdrop.isOpaque ? background.withAlphaComponent(1).cgColor : nil
            backdropView.apply(backdrop, tint: background)
        }
    }

    /// Sets `window`'s opacity and background for this view's theme.
    /// Values that already match are not written again, so a repeat call
    /// (an appearance change while the window installs this view) never
    /// touches the theme frame.
    func applyBackdrop(to window: NSWindow) {
        let backdrop = self.backdrop
        let color = backdrop.isOpaque
            ? performWithTheme { Palette.windowBackground.withAlphaComponent(1) }
            : NSColor.white.withAlphaComponent(backdrop.windowBackgroundAlpha)
        if window.isOpaque != backdrop.isOpaque { window.isOpaque = backdrop.isOpaque }
        if window.backgroundColor != color { window.backgroundColor = color }
    }
}

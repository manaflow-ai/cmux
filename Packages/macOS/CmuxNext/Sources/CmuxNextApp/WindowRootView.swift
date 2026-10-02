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
/// terminal read as one sheet with no panel edges or seams.
final class WindowRootView: NSView {
    let titlebar = TitlebarView()
    /// The window's one material and tint (`WindowBackdrop`).
    let backdropView = WindowMaterialView(frame: .zero)
    private let reduceTransparency: @MainActor () -> Bool
    private let contentHost = NSView()
    private let sidebar: SidebarContainerView
    private var titleHeight: NSLayoutConstraint?
    private var tokenObservation: Task<Void, Never>?
    private(set) weak var content: NSView?
    /// Empties AppKit's titlebar drag region: the window moves only through
    /// `TitlebarDragPolicy` (`ShellWindow.sendEvent`).
    let titlebarBandBlocker = TitlebarDragBlocker(frame: .zero)

    init(sidebar: SidebarContainerView,
         reduceTransparency: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }) {
        self.sidebar = sidebar
        self.reduceTransparency = reduceTransparency
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
        // Below required, so it yields to the traffic-light inset.
        let titleFollowsSidebar = titlebar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        titleFollowsSidebar.priority = .required - 1
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            titlebar.topAnchor.constraint(equalTo: topAnchor),
            titlebar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleHeight,
            titleFollowsSidebar,
            // When the sidebar hides, the title stops clear of the traffic
            // lights while the content below reaches the window edge.
            titlebar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.trafficLightInset),
            contentHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: titlebar.bottomAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.titleHeight = titleHeight
        applyTokens()
        tokenObservation = Task { [weak self] in
            for await _ in Observations({ [Metrics.titlebarHeight, Metrics.tabStripHeight, DesignSettings.shared.titlebar == .minimal ? 1 : 0] }) {
                self?.applyTokens()
            }
        }
        themeDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        tokenObservation?.cancel()
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

    /// Surface color plus window opacity: a translucent Ghostty background
    /// (`background-opacity`) makes the whole window translucent, like
    /// Ghostty.app, with its `background-blur` radius behind it
    /// (`WindowBackdrop`).
    func themeDidChange() {
        paintBackground()
        if let window { applyBackdrop(to: window) }
    }

    var backdrop: WindowBackdrop {
        WindowBackdrop(themeTokens, reduceTransparency: reduceTransparency())
    }

    private func paintBackground() {
        layer?.backgroundColor = performWithTheme { Palette.windowBackground }.cgColor
    }

    /// Sets `window`'s opacity, background and blur for this view's theme.
    /// Values that already match are not written again, so a repeat call
    /// (an appearance change while the window installs this view) never
    /// touches the theme frame.
    func applyBackdrop(to window: NSWindow) {
        let tokens = themeTokens
        let backdrop = WindowBackdrop(tokens)
        let color = backdrop.isOpaque
            ? performWithTheme { Palette.windowBackground }
            : NSColor.white.withAlphaComponent(backdrop.windowBackgroundAlpha)
        if window.isOpaque != backdrop.isOpaque { window.isOpaque = backdrop.isOpaque }
        if window.backgroundColor != color { window.backgroundColor = color }
        if !backdrop.isOpaque && tokens.backgroundBlur >= 0 { GhosttyRuntime.shared.applyBackgroundBlur(to: window) }
    }
}

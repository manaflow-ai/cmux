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
    private let contentHost = NSView()
    private let sidebar: SidebarContainerView
    private var titleHeight: NSLayoutConstraint?
    private var tokenObservation: Task<Void, Never>?
    private(set) weak var content: NSView?

    init(sidebar: SidebarContainerView) {
        self.sidebar = sidebar
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        wantsLayer = true
        for view in [contentHost, titlebar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addSubview(sidebar)
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
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        themeDidChange()
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
        let tokens = ThemeStore.shared.tokens
        let backdrop = WindowBackdrop(backgroundOpacity: tokens.backgroundOpacity, backgroundBlur: tokens.backgroundBlur)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.windowBackground.cgColor
        }
        guard let window else { return }
        window.isOpaque = backdrop.isOpaque
        window.backgroundColor = backdrop.isOpaque
            ? Palette.windowBackground
            : NSColor.white.withAlphaComponent(backdrop.windowBackgroundAlpha)
        if backdrop.appliesBlur { GhosttyRuntime.shared.applyBackgroundBlur(to: window) }
    }
}

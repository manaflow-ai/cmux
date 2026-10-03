public import AppKit
import CmuxNextDesign
import CmuxNextTerminalFind

/// Container the App embeds. Holds the current surface view (swapped on
/// replay) and paints the terminal's background (its theme's, else the
/// config's) behind an announced grid that is smaller than the view.
///
/// The surface fills the host, which fills the pane's content border, so
/// the first cell sits exactly Ghostty's padding inside the border
/// (`TerminalPadding.cmuxDefault` unless the user set their own).
public final class TerminalHostView: NSView {
    private weak var current: TerminalSurfaceView?
    /// The session's theme; nil paints the config background.
    var theme: GhosttyThemeConfig? {
        didSet { paintBackground() }
    }
    /// Shown over the last screen while the link is down (click-through).
    private let banner = TerminalStatusBanner()
    private var shownStatus: TerminalConnectionStatus = .connected
    /// "Restart Shell Here" and "Close" above the banner while the shell has ended.
    private let deadTabBar = TerminalDeadTabBar()
    /// The App's dead-tab actions (`tab.restart`, `closeTab`) for this tab.
    public var deadTabActions = TerminalDeadTabActions() {
        didSet { deadTabBar.update(exited: shownStatus == .exited, actions: deadTabActions) }
    }

    /// The first cell's top-left in this view's coordinates (top-left
    /// origin): Ghostty's leading and top padding, or with
    /// `window-padding-balance` half the grid's leftover (for `debug.pane_chrome`).
    public var firstCellOrigin: CGPoint {
        let padding = GhosttyRuntime.shared.terminalPadding
        guard padding.balanced, let model = current?.session?.model, let grid = model.grid, grid.columns > 0, grid.rows > 0 else {
            return CGPoint(x: padding.leading, y: padding.top)
        }
        let scale = window?.backingScaleFactor ?? 2
        let gridWidth = CGFloat(grid.columns) * model.cellPixelSize.width / scale
        let gridHeight = CGFloat(grid.rows) * model.cellPixelSize.height / scale
        return CGPoint(x: max(padding.leading, (bounds.width - gridWidth) / 2), y: max(padding.top, (bounds.height - gridHeight) / 2))
    }

    private var configObserver: (any NSObjectProtocol)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        paintBackground()
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            banner.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        deadTabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deadTabBar, positioned: .above, relativeTo: banner)
        NSLayoutConstraint.activate([
            deadTabBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            deadTabBar.bottomAnchor.constraint(equalTo: banner.topAnchor, constant: -8),
        ])
        // A config reload can change window-padding-x.
        configObserver = NotificationCenter.default.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }

    /// Pins the session's find bar to the top-trailing corner, above the
    /// surface and the status banner.
    func attachFind(_ find: TerminalFindController) {
        let bar = TerminalFindBarView(find: find)
        addSubview(bar, positioned: .above, relativeTo: banner)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.panelInset),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.panelInset),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.panelInset),
        ])
    }

    /// The link status label over the terminal (hidden while connected).
    var statusText: String? { banner.isHidden ? nil : TerminalStatusBanner.text(for: shownStatus) }

    func showStatus(_ status: TerminalConnectionStatus) {
        shownStatus = status
        banner.show(status)
        deadTabBar.update(exited: status == .exited, actions: deadTabActions)
    }

    isolated deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func install(_ surfaceView: TerminalSurfaceView) {
        let old = current
        surfaceView.autoresizingMask = []
        surfaceView.frame = bounds
        // Below the status banner, which stays over every swapped-in surface.
        addSubview(surfaceView, positioned: .below, relativeTo: banner)
        current = surfaceView
        old?.removeFromSuperview()
    }

    public override func layout() {
        super.layout()
        if let current, current.frame != bounds { current.frame = bounds }
    }

    /// Anything that lands on the host itself goes to the surface.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self, let current else { return hit }
        return current
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintBackground()
    }

    /// Opaque windows only, like `GhosttyRuntime.backgroundColor`: in a
    /// translucent window the window root paints the one sheet.
    private func paintBackground() {
        let runtime = GhosttyRuntime.shared
        guard let rgb = theme?.colors?.background, runtime.backgroundOpacity >= 1 else {
            layer?.backgroundColor = runtime.backgroundColor.cgColor
            return
        }
        layer?.backgroundColor = CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

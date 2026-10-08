public import AppKit
import CmuxNextDesign
import CmuxNextTerminalFind
import Observation

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
    /// The scroller, per the macOS "Show scroll bars" setting (SCROLLBARS-FOLLOW-MACOS).
    private let scroller = TerminalScroller()
    private var shownStatus: TerminalConnectionStatus = .connected
    private var hostLoss: TerminalHostLoss?
    private var hostLossCause: TerminalHostLossCause?

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
        let width = bounds.width - scroller.reservedWidth
        return CGPoint(x: max(padding.leading, (width - gridWidth) / 2), y: max(padding.top, (bounds.height - gridHeight) / 2))
    }

    private var configObserver: (any NSObjectProtocol)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        paintBackground()
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)
        addSubview(scroller, positioned: .below, relativeTo: banner)
        scroller.onStyleChange = { [weak self] in self?.needsLayout = true }
        scroller.onScrollToRow = { [weak self] row in _ = self?.current?.performBindingAction("scroll_to_row:\(row)") }
        scroller.onWheel = { [weak self] event in self?.current?.scrollWheel(with: event) }
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: centerXAnchor),
            banner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            banner.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        // A config reload can change window-padding-x.
        configObserver = NotificationCenter.default.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }

    /// Pins the session's find bar to the top-trailing corner, above the
    /// surface and the status banner.
    /// The find bar is built the first time find opens, not with the
    /// terminal: its glass panel, stack and buttons cost about 5 ms of main
    /// thread per new terminal (R81 trace), most of a 120 Hz frame.
    func attachFind(_ find: TerminalFindController) {
        if find.isPresented { return installFindBar(find) }
        withObservationTracking {
            _ = find.isPresented
        } onChange: { [weak self, weak find] in
            Task { @MainActor in
                guard let self, let find else { return }
                self.attachFind(find)
            }
        }
    }

    private func installFindBar(_ find: TerminalFindController) {
        guard !subviews.contains(where: { $0 is TerminalFindBarView }) else { return }
        let bar = TerminalFindBarView(find: find)
        addSubview(bar, positioned: .above, relativeTo: banner)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.panelInset),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.panelInset),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Metrics.panelInset),
        ])
    }

    /// The link status label over the terminal (hidden while connected).
    var statusText: String? {
        banner.isHidden ? nil : TerminalStatusBanner.text(for: shownStatus, hostLoss: hostLoss, cause: hostLossCause)
    }

    func showStatus(_ status: TerminalConnectionStatus) {
        shownStatus = status
        banner.show(status, hostLoss: hostLoss, cause: hostLossCause)
    }

    func showHostLoss(_ loss: TerminalHostLoss?, cause: TerminalHostLossCause?) {
        hostLoss = loss
        hostLossCause = cause
        banner.show(shownStatus, hostLoss: loss, cause: cause)
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
        surfaceView.frame = surfaceFrame
        // Below the scroller and the status banner, which stay over every swapped-in surface.
        addSubview(surfaceView, positioned: .below, relativeTo: scroller)
        current = surfaceView
        old?.removeFromSuperview()
        followScrollbar(of: surfaceView)
    }

    /// Shows the surface's scrollbar state (Ghostty's scrollbar action) on the scroller, now and on
    /// every change, while the surface is the current one.
    private func followScrollbar(of surfaceView: TerminalSurfaceView) {
        guard current === surfaceView, let model = surfaceView.session?.model else { return }
        let bar = withObservationTracking { model.scrollbar } onChange: { [weak self, weak surfaceView] in
            Task { @MainActor in
                guard let self, let surfaceView else { return }
                self.followScrollbar(of: surfaceView)
            }
        }
        scroller.update(bar)
    }

    /// The surface's frame: the host, less the legacy scroller's strip ("Always").
    private var surfaceFrame: CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: max(0, bounds.width - scroller.reservedWidth), height: bounds.height)
    }

    public override func layout() {
        super.layout()
        if let current, current.frame != surfaceFrame { current.frame = surfaceFrame }
        let strip = scroller.strip(in: bounds)
        if scroller.frame != strip { scroller.frame = strip }
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
    /// translucent window the window root paints the one sheet. The user's
    /// terminal background (`appearance.surfaces.terminal`) replaces both;
    /// the surfaces then draw a transparent default background.
    private func paintBackground() {
        let fill = performWithTheme { Palette.surfaceOverride(.terminal) }
        if let fill {
            layer?.backgroundColor = fill.cgColor
            return
        }
        let runtime = GhosttyRuntime.shared
        guard let rgb = theme?.colors?.background, runtime.backgroundOpacity >= 1 else {
            layer?.backgroundColor = runtime.backgroundColor.cgColor
            return
        }
        layer?.backgroundColor = CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

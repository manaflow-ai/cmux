public import AppKit
import CmuxNextDesign

/// Container the App embeds. Holds the current surface view (swapped on
/// replay) and paints the terminal's background (its theme's, else the
/// config's) behind an announced grid that is smaller than the view.
///
/// The surface sits inset horizontally so the first text column lands on
/// the pane's content line (`Metrics.paneContentInset`), level with the tab
/// icons above it. Ghostty's own `window-padding-x` (read from the config,
/// `GhosttyRuntime.terminalPadding`) is inside the surface, so the host adds
/// only the rest, on each side from that side's padding.
public final class TerminalHostView: NSView {
    private weak var current: TerminalSurfaceView?
    /// The session's theme; nil paints the config background.
    var theme: GhosttyThemeConfig? {
        didSet { paintBackground() }
    }
    /// Shown over the last screen while the link is down (click-through).
    private let banner = TerminalStatusBanner()
    private var shownStatus: TerminalConnectionStatus = .connected

    /// The surface frame in a host of `bounds` (pure): inset so the first
    /// column (after Ghostty's leading padding) starts at `contentInset`,
    /// and the last one ends as far from the trailing edge; a host too
    /// narrow for the insets keeps its width. With `window-padding-balance`
    /// Ghostty centers the grid in leftover space, so the column can sit up
    /// to half a cell further in.
    static func surfaceFrame(in bounds: CGRect, contentInset: CGFloat, padding: TerminalPadding = .ghosttyDefault) -> CGRect {
        let leading = max(0, contentInset - padding.leading)
        let trailing = max(0, contentInset - padding.trailing)
        guard bounds.width > (leading + trailing) * 2 else { return bounds }
        return CGRect(x: bounds.minX + leading, y: bounds.minY, width: bounds.width - leading - trailing, height: bounds.height)
    }

    private var surfaceFrame: CGRect {
        Self.surfaceFrame(in: bounds, contentInset: Metrics.paneContentInset, padding: GhosttyRuntime.shared.terminalPadding)
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
        // A config reload can change window-padding-x.
        configObserver = NotificationCenter.default.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }

    /// The link status label over the terminal (hidden while connected).
    var statusText: String? { banner.isHidden ? nil : TerminalStatusBanner.text(for: shownStatus) }

    func showStatus(_ status: TerminalConnectionStatus) {
        shownStatus = status
        banner.show(status)
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
        // Below the status banner, which stays over every swapped-in surface.
        addSubview(surfaceView, positioned: .below, relativeTo: banner)
        current = surfaceView
        old?.removeFromSuperview()
    }

    /// Reads the token in layout, so a density change re-lays out.
    public override func layout() {
        super.layout()
        let frame = surfaceFrame
        if let current, current.frame != frame { current.frame = frame }
    }

    /// The side gutters belong to the terminal: a click or drag there goes
    /// to the surface (Ghostty clamps it to the first or last column).
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

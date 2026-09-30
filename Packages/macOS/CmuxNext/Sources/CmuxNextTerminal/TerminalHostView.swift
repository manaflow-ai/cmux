public import AppKit
import CmuxNextDesign

/// Container the App embeds. Holds the current surface view (swapped on
/// replay) and paints the terminal's background (its theme's, else the
/// config's) behind an announced grid that is smaller than the view.
///
/// The surface sits inset horizontally so the first text column lands on
/// the pane's content line (`Metrics.paneContentInset`), level with the tab
/// icons above it. Ghostty's own `window-padding-x` is inside the surface,
/// so the host adds only the rest; libghostty's config API does not expose
/// that key, so the host counts Ghostty's default (2 pt).
public final class TerminalHostView: NSView {
    private weak var current: TerminalSurfaceView?
    /// The session's theme; nil paints the config background.
    var theme: GhosttyThemeConfig? {
        didSet { paintBackground() }
    }
    /// Shown over the last screen while the link is down (click-through).
    private let banner = TerminalStatusBanner()
    private var shownStatus: TerminalConnectionStatus = .connected

    /// Ghostty's default `window-padding-x`.
    static let ghosttyDefaultPaddingX: CGFloat = 2

    /// The surface frame in a host of `bounds` (pure): inset on both sides
    /// so the first column (after Ghostty's padding) starts at
    /// `contentInset`; a host too narrow for the insets keeps its width.
    static func surfaceFrame(in bounds: CGRect, contentInset: CGFloat, paddingX: CGFloat = ghosttyDefaultPaddingX) -> CGRect {
        let inset = max(0, contentInset - paddingX)
        guard bounds.width > inset * 4 else { return bounds }
        return bounds.insetBy(dx: inset, dy: 0)
    }

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
    }

    /// The link status label over the terminal (hidden while connected).
    var statusText: String? { banner.isHidden ? nil : TerminalStatusBanner.text(for: shownStatus) }

    func showStatus(_ status: TerminalConnectionStatus) {
        shownStatus = status
        banner.show(status)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func install(_ surfaceView: TerminalSurfaceView) {
        let old = current
        surfaceView.autoresizingMask = []
        surfaceView.frame = Self.surfaceFrame(in: bounds, contentInset: Metrics.paneContentInset)
        // Below the status banner, which stays over every swapped-in surface.
        addSubview(surfaceView, positioned: .below, relativeTo: banner)
        current = surfaceView
        old?.removeFromSuperview()
    }

    /// Reads the token in layout, so a density change re-lays out.
    public override func layout() {
        super.layout()
        let frame = Self.surfaceFrame(in: bounds, contentInset: Metrics.paneContentInset)
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

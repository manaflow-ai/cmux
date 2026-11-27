import AppKit

/// cmux (Lawrence, 2026-10-20: "chief fade is not liquid glassy enough and covers too much
/// stuff"): Home's header as Messages draws it on macOS 26. A thin glass band, only as tall as the
/// avatar and the name pill (`PaneHeaderView`), whose bottom edge fades out over a few points; the
/// rows scroll under it at full strength and the glass blurs them. It replaces the hover-only dark
/// fade and the rows' mask under the header (2026-10-08, u2891), which dimmed and hid rows well
/// below the pill. System Liquid Glass on macOS 26 and newer, a visual-effect view before
/// (`LabGlass`). The band takes no clicks: the header controls and the transcript keep them.
final class HeaderGlassView: NSView {
    /// The solid glass ends this far under the name pill.
    static let belowPill: CGFloat = 4
    /// The soft bottom edge, where the glass fades out over the rows.
    static let softEdge: CGFloat = 10
    /// The band's height: to the pill's bottom, `belowPill`, then the soft edge.
    static var height: CGFloat { PaneHeaderView.pillCenterY + PaneHeaderView.pillHeight / 2 + belowPill + softEdge }

    let surface = LabGlass.surface()
    private let edge = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        surface.cornerRadius = 0
        addSubview(surface)
        edge.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull()]
        // The view is flipped: (0.5, 0) is the top of the band.
        edge.startPoint = CGPoint(x: 0.5, y: 0)
        edge.endPoint = CGPoint(x: 0.5, y: 1)
        edge.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        layer?.mask = edge
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        surface.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edge.frame = bounds
        let h = max(1, bounds.height)
        edge.locations = [0, NSNumber(value: Double(max(0, h - Self.softEdge) / h)), 1]
        CATransaction.commit()
    }
}

extension HostView {
    /// Puts the glass band over the transcript, under the header controls, and hides the old
    /// blurred band (`headerBackdrop`). Once per pane.
    func useHeaderGlass() {
        guard headerGlass == nil else { return }
        let glass = HeaderGlassView(frame: .zero)
        // Hidden until a row is under it (`updateTopFadeScrollEdge`).
        glass.isHidden = true
        addSubview(glass, positioned: .below, relativeTo: paneHeader)
        headerGlass = glass
        headerBackdrop.isHidden = true
        needsLayout = true
    }

    /// cmux (Leo 2026-10-21: "why is there a top banner? ... we don't even need this"): no header.
    /// No avatar, no name pill and no band over the transcript: the rows start `bareTopInset` under
    /// the pane's top and fade out over the last `bareTopInset` points as they scroll away, so nothing
    /// ever sits on text (`placeNativeViews` hands the window view the inset and the fade). Replaces
    /// `useHeaderGlass`; once per pane.
    func useBareTop() {
        guard !bareTop, headerGlass == nil else { return }
        bareTop = true
        paneHeader.bare = true
        headerBackdrop.isHidden = true
        needsLayout = true
    }

    /// The rows' top at rest, and the fade over it, in a pane with no header.
    static let bareTopInset: CGFloat = 16

    /// The rows' top at rest with no header: under the top-right controls when the pane has them.
    var bareRowsTop: CGFloat {
        guard let accessory = paneHeader.trailingAccessory else { return Self.bareTopInset }
        let height = accessory.intrinsicContentSize.height
        return PaneHeaderView.bareAccessoryTop + (height == NSView.noIntrinsicMetric ? accessory.frame.height : height) + 8
    }

    /// Follows the pane's width (called from `placeNativeViews`).
    func placeHeaderGlass() {
        guard let headerGlass else { return }
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: HeaderGlassView.height)
        if headerGlass.frame != frame { headerGlass.frame = frame }
    }
}

extension MessagesLabHomeView {
    /// cmux: Home's header is a thin glass band over the transcript (`HeaderGlassView`), and the
    /// name pill is glass with nothing dark behind it.
    public func setHeaderGlass() {
        controller.host.useHeaderGlass()
        controller.host.paneHeader.useGlassPill()
    }

    /// The header's glass band (nil before `setHeaderGlass`).
    var headerGlass: HeaderGlassView? { controller.host.headerGlass }

    /// cmux: no header (`HostView.useBareTop`): the rows start near the top and fade out there.
    /// Use instead of ``setHeaderGlass()``, not after it.
    public func setBareTop() { controller.host.useBareTop() }
}

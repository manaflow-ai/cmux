import AppKit

/// cmux (Lawrence, 2026-10-08): the header's band shows only while the
/// pointer is near the top of the transcript, as a light gradient of the
/// window background that blends into whatever is behind the pane (the
/// background image), never MessagesLab's always-on blurred band. The
/// avatar and the name pill (`PaneHeaderView`) stay as they are, and the
/// band still drags the window (the backdrop takes no clicks).
///
/// cmux-classic: the band also shows, at rest, whenever a row lies under the
/// header (the transcript is scrolled away from its top): hover-only left the
/// avatar and pill over bubble text. `setHeaderFade(…, extent:)` makes it cover
/// the header's controls plus what the host draws under them (Chief's model
/// line), solid down to `extent - solidFadeLength` and fading below.

/// Reports the pointer entering and leaving the header's top zone.
final class HeaderZoneTracker: NSResponder {
    var onChange: (Bool) -> Void = { _ in }
    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}

extension HeaderBackdropView {
    /// Replaces the blur with a top-to-bottom gradient of `color` from
    /// `maxAlpha` to clear, hidden until `setRevealed(true)`. `solid`: the share of
    /// the band (0 to 1) that stays at `maxAlpha` before it fades (0: fades all the way).
    func useTopFade(color: NSColor, maxAlpha: CGFloat, solid: CGFloat = 0) {
        let fade: CAGradientLayer
        if let existing = topFade {
            fade = existing
        } else {
            fade = CAGradientLayer()
            fade.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull()]
            // The layer is flipped: (0.5, 0) is the top of the pane.
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
            for layer in root.sublayers ?? [] { layer.isHidden = true }
            root.addSublayer(fade)
            root.opacity = 0
            topFade = fade
            needsLayout = true
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if solid > 0 {
            let top = color.withAlphaComponent(maxAlpha).cgColor
            fade.colors = [top, top, color.withAlphaComponent(0).cgColor]
            fade.locations = [0, NSNumber(value: Double(min(1, solid))), 1]
        } else {
            fade.colors = [color.withAlphaComponent(maxAlpha).cgColor, color.withAlphaComponent(0).cgColor]
            fade.locations = nil
        }
        CATransaction.commit()
    }

    /// The top fade's strongest alpha (0 without one).
    var topFadeMaxAlpha: CGFloat {
        guard let raw = topFade?.colors?.first else { return 0 }
        let first = raw as AnyObject
        guard CFGetTypeID(first) == CGColor.typeID else { return 0 }
        return unsafeDowncast(first, to: CGColor.self).alpha
    }

    /// Shows or hides the top fade over `duration` (0: at once), easing.
    func setRevealed(_ revealed: Bool, duration: TimeInterval) {
        guard topFade != nil else { return }
        let target: Float = revealed ? 1 : 0
        guard root.opacity != target else { return }
        lastFadeDuration = duration
        let from = root.presentation()?.opacity ?? root.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.opacity = target
        CATransaction.commit()
        root.removeAnimation(forKey: "cmux.topFade")
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.add(animation, forKey: "cmux.topFade")
    }

    /// The top fade's opacity as set (0 hidden, 1 shown).
    var revealOpacity: Float { topFade == nil ? 1 : root.opacity }
}

extension HostView {
    /// Sets `appearance` on each view that does not have it already (compared by name: a set
    /// re-resolves every layer under it).
    static func pinAppearance(_ views: [NSView], _ appearance: NSAppearance?) {
        for view in views where view.appearance?.name != appearance?.name { view.appearance = appearance }
    }

    /// The zone over the header plus a small margin, tracked only once the
    /// top fade is in use.
    static let headerZoneMargin: CGFloat = 16
    /// The fading part at the bottom of an extended band (`setHeaderFade(…, extent:)`).
    static let solidFadeLength: CGFloat = 18

    /// The band's height: the extent the host asked for, else the backdrop's own.
    var headerBandHeight: CGFloat { max(headerBackdrop.totalHeight, headerFadeExtent ?? 0) }

    /// Whether the band shows: the pointer is near the top, or (when the host asked for it)
    /// a row lies under the band: the oldest row's top (`rowsTop`, this view's y; nil without
    /// rows) is above the band's bottom (`band`). Pure, for tests.
    static func headerRevealed(hovered: Bool, revealsWhenScrolled: Bool, rowsTop: CGFloat?, band: CGFloat) -> Bool {
        guard !hovered else { return true }
        guard revealsWhenScrolled, let rowsTop else { return false }
        return rowsTop < band - 0.5
    }

    /// The oldest row's top in this view (nil without rows): from the transcript's own geometry,
    /// so it is right after a scroll, a new row pushing the others up, a width pass (a panel
    /// opening beside the pane) and a height change alike.
    var transcriptRowsTop: CGFloat? {
        guard let demo, demo.model.count > 0 else { return nil }
        let y = demo.windowY(contentY: demo.layout.rowsTop) + demo.frame.minY
        return y.isFinite ? y : nil
    }

    /// Shows or hides the band for the pointer and the rows under it. cmux-classic: called on every
    /// scroll, every engine change (`ChatController.afterEngine`) and every layout
    /// (`placeNativeViews`), not only on scroll events: rows that grew under the header with no
    /// scroll left the avatar, pill and model line over bubble text.
    func applyHeaderReveal() {
        applyFooterFade()  // the band under the field follows the same changes (FooterFade.swift)
        guard headerBackdrop.topFade != nil else { return }
        let shown = Self.headerRevealed(hovered: headerHovered, revealsWhenScrolled: headerRevealsWhenScrolled,
                                        rowsTop: transcriptRowsTop, band: headerBandHeight)
        headerBackdrop.setRevealed(shown, duration: headerFadeDuration(shown))
    }

    func updateHeaderZone() {
        if let area = headerZoneArea { removeTrackingArea(area); headerZoneArea = nil }
        guard headerBackdrop.topFade != nil, bounds.width > 0 else { return }
        let rect = CGRect(x: 0, y: 0, width: bounds.width, height: Fixture.headerHeight + Self.headerZoneMargin)
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: headerZone)
        addTrackingArea(area)
        headerZoneArea = area
    }
}

extension MessagesLabHomeView {
    /// cmux: the header's band becomes a light fade of `color` (at most
    /// `maxAlpha`) shown only while the pointer is near the top;
    /// `duration(shown)` gives each show or hide its length (0: at once).
    ///
    /// cmux-classic: `revealsWhenScrolled` also shows it at rest while a row lies under the
    /// header; `extent` (points from the top) makes the band reach below the header's own
    /// height, solid until its last `HostView.solidFadeLength` points.
    public func setHeaderFade(color: NSColor, maxAlpha: CGFloat, extent: CGFloat? = nil, revealsWhenScrolled: Bool = false,
                              duration: @escaping (Bool) -> TimeInterval) {
        let host = controller.host
        let first = host.headerBackdrop.topFade == nil
        host.headerFadeExtent = extent
        let band = host.headerBandHeight
        let solid = extent == nil || band <= 0 ? 0 : max(0, band - HostView.solidFadeLength) / band
        host.headerBackdrop.useTopFade(color: color, maxAlpha: maxAlpha, solid: solid)
        host.headerRevealsWhenScrolled = revealsWhenScrolled
        host.headerFadeDuration = duration
        host.headerZone.onChange = { [weak host] hovered in
            host?.headerHovered = hovered
            host?.applyHeaderReveal()
        }
        if first { host.updateHeaderZone() }
        host.needsLayout = true
        host.applyHeaderReveal()
    }

    /// cmux: the name pill's own translucent capsule, always shown.
    public func setHeaderPillBacking(_ color: NSColor) { controller.host.paneHeader.setPillBacking(color) }

    /// cmux-classic: the header (avatar, the pill's glass, the band) resolves in `appearance`, the
    /// host's theme (Chief: the terminal theme's light or dark), never the app's: a dark terminal
    /// theme in a light app drew a light grey pill with mid-grey text on the dark pane. Nil follows
    /// the superview again.
    public func setHeaderAppearance(_ appearance: NSAppearance?) {
        HostView.pinAppearance([controller.host.paneHeader, controller.host.headerBackdrop], appearance)
    }

    /// The header fade's opacity as set (0 hidden, 1 shown).
    public var headerFadeOpacity: Float { controller.host.headerBackdrop.revealOpacity }
    /// The header fade's strongest alpha.
    public var headerFadeMaxAlpha: CGFloat { controller.host.headerBackdrop.topFadeMaxAlpha }
    /// The tracking area of the header's top zone (nil before `setHeaderFade`).
    public var headerZoneTrackingArea: NSTrackingArea? { controller.host.headerZoneArea }
    /// The length of the last show or hide.
    public var lastHeaderFadeDuration: TimeInterval { controller.host.headerBackdrop.lastFadeDuration }
}

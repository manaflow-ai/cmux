import AppKit

/// cmux (Lawrence, 2026-10-08): the header's band shows only while the
/// pointer is near the top of the transcript, as a light gradient of the
/// window background that blends into whatever is behind the pane (the
/// background image), never MessagesLab's always-on blurred band. The
/// avatar and the name pill (`PaneHeaderView`) stay as they are, and the
/// band still drags the window (the backdrop takes no clicks).

/// Reports the pointer entering and leaving the header's top zone.
final class HeaderZoneTracker: NSResponder {
    var onChange: (Bool) -> Void = { _ in }
    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}

extension HeaderBackdropView {
    /// Replaces the blur with a top-to-bottom gradient of `color` from
    /// `maxAlpha` to clear, hidden until `setRevealed(true)`.
    func useTopFade(color: NSColor, maxAlpha: CGFloat) {
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
        fade.colors = [color.withAlphaComponent(maxAlpha).cgColor, color.withAlphaComponent(0).cgColor]
        CATransaction.commit()
    }

    /// The top fade's strongest alpha (0 without one).
    var topFadeMaxAlpha: CGFloat {
        guard let first = (topFade?.colors?.first).map({ $0 as! CGColor }) else { return 0 }
        return first.alpha
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
    /// The zone over the header plus a small margin, tracked only once the
    /// top fade is in use.
    static let headerZoneMargin: CGFloat = 16

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
    public func setHeaderFade(color: NSColor, maxAlpha: CGFloat, duration: @escaping (Bool) -> TimeInterval) {
        let host = controller.host
        let first = host.headerBackdrop.topFade == nil
        host.headerBackdrop.useTopFade(color: color, maxAlpha: maxAlpha)
        host.headerZone.onChange = { [weak host] shown in
            host?.headerBackdrop.setRevealed(shown, duration: duration(shown))
        }
        if first { host.updateHeaderZone() }
    }

    /// cmux: the name pill's own translucent capsule, always shown.
    public func setHeaderPillBacking(_ color: NSColor) { controller.host.paneHeader.setPillBacking(color) }

    /// The header fade's opacity as set (0 hidden, 1 shown).
    public var headerFadeOpacity: Float { controller.host.headerBackdrop.revealOpacity }
    /// The header fade's strongest alpha.
    public var headerFadeMaxAlpha: CGFloat { controller.host.headerBackdrop.topFadeMaxAlpha }
    /// The tracking area of the header's top zone (nil before `setHeaderFade`).
    public var headerZoneTrackingArea: NSTrackingArea? { controller.host.headerZoneArea }
    /// The length of the last show or hide.
    public var lastHeaderFadeDuration: TimeInterval { controller.host.headerBackdrop.lastFadeDuration }
}

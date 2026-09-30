import AppKit
import SwiftUI

/// Draws a compact status glyph in both sidebar engines. The running pulse
/// is a Core Animation opacity loop run by the render server, gated like
/// `GPUSpinnerNSView`: it stops while the view or an ancestor is hidden, the
/// window is occluded, the row is suspended, or Reduce Motion is on; it asks
/// for at most 30 Hz; and every pulsing row shares one phase.
final class SidebarCompactStatusGlyphImageView: NSImageView {
    private static let pulseKey = "cmux.compactStatus.pulse"
    private static let pulseDuration: CFTimeInterval = 0.9
    private var pulses = false

    /// Cleared by a suspended AppKit cell, like the spinner's flag.
    var isPresentationActive = true {
        didSet { if oldValue != isPresentationActive { updatePulse() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // One mode for both engines, set here so no host can disagree.
        // Proportionally-down keeps a symbol that is wider than it is tall
        // (a warning triangle, a branch) inside the square slot instead of
        // clipping it, and leaves the smaller dot images at natural size.
        imageScaling = .scaleProportionallyDown
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(visibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func configure(_ glyph: SidebarCompactStatusGlyph, pointSize: CGFloat, color: NSColor) {
        image = Self.image(glyph, pointSize: pointSize)
            ?? Self.image(glyph.droppingCustomSymbol, pointSize: pointSize)
        contentTintColor = color
        toolTip = glyph.tooltip.isEmpty ? nil : glyph.tooltip
        setAccessibilityElement(!glyph.tooltip.isEmpty)
        setAccessibilityLabel(glyph.tooltip)
        setAccessibilityRole(.image)
        if pulses != glyph.pulses {
            pulses = glyph.pulses
            updatePulse()
        }
    }

    private struct ImageKey: Hashable {
        let symbol: String
        let badge: String?
        let pointSize: CGFloat
    }

    /// A dozen glyph slots times the handful of point sizes the sidebar's font
    /// scale and global magnification produce, plus room for user-configured
    /// `sidebar.compactStatusIcons` symbols. Bounded because the point size is
    /// continuous: dragging the font scale slider would otherwise mint a new
    /// entry per intermediate value and never release one, the same reason
    /// `RenderableSystemSymbol` bounds its own AppKit image cache.
    private static let imageCacheLimit = 64

    @MainActor private static var imageCache: [ImageKey: NSImage] = [:]
    @MainActor private static var imageCacheInsertionOrder: [ImageKey] = []

    @MainActor private static func cache(_ image: NSImage, for key: ImageKey) {
        guard imageCache.updateValue(image, forKey: key) == nil else { return }
        imageCacheInsertionOrder.append(key)
        while imageCacheInsertionOrder.count > imageCacheLimit {
            imageCache.removeValue(forKey: imageCacheInsertionOrder.removeFirst())
        }
    }

    /// The glyph's image at the row's point size, scaled by the glyph's own
    /// ``SidebarCompactStatusGlyph/sizeScale`` so the built-in dots stay small.
    @MainActor static func image(_ glyph: SidebarCompactStatusGlyph, pointSize: CGFloat) -> NSImage? {
        image(
            symbol: glyph.symbolName,
            badge: glyph.badgeSymbolName,
            pointSize: (pointSize * glyph.sizeScale).rounded()
        )
    }

    /// The glyph's template image; a badge is knocked out of the base symbol's
    /// lower trailing corner so it reads at sidebar size. Cached per key.
    @MainActor static func image(symbol: String, badge: String?, pointSize: CGFloat) -> NSImage? {
        let key = ImageKey(symbol: symbol, badge: badge, pointSize: pointSize)
        if let cached = imageCache[key] { return cached }
        guard let base = SidebarCompactStatusDrawnGlyph(rawValue: symbol)?.image(pointSize: pointSize)
            ?? RenderableSystemSymbol.configuredAppKitImage(
                systemName: symbol, pointSize: pointSize, weight: .semibold
            ) else { return nil }
        guard let badge, let badgeImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: badge, pointSize: pointSize * 0.62, weight: .bold
        ) else {
            cache(base, for: key)
            return base
        }
        let size = base.size
        let composed = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let side = min(rect.width, rect.height) * 0.62
            let badgeRect = NSRect(x: rect.maxX - side, y: rect.minY, width: side, height: side)
            guard let context = NSGraphicsContext.current else { return true }
            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
            context.compositingOperation = .sourceOver
            badgeImage.draw(in: badgeRect)
            return true
        }
        composed.isTemplate = true
        cache(composed, for: key)
        return composed
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        updatePulse()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePulse()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePulse()
    }

    @objc private func visibilityChanged() {
        updatePulse()
    }

    private var shouldPulse: Bool {
        guard pulses, isPresentationActive, !isHiddenOrHasHiddenAncestor else { return false }
        guard let window, window.occlusionState.contains(.visible) else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updatePulse() {
        guard let layer else { return }
        guard shouldPulse else {
            layer.removeAnimation(forKey: Self.pulseKey)
            return
        }
        guard layer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = Self.pulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        // Anchor to the shared media clock so every pulsing row is in phase.
        let globalNow = CACurrentMediaTime()
        let period = Self.pulseDuration * 2
        pulse.beginTime = layer.convertTime(globalNow, from: nil) - globalNow.truncatingRemainder(dividingBy: period)
        layer.add(pulse, forKey: Self.pulseKey)
    }
}

/// SwiftUI rendering for the default sidebar list. Takes resolved values
/// only; no store access below the lazy-list boundary.
struct SidebarCompactStatusGlyphView: NSViewRepresentable {
    let glyph: SidebarCompactStatusGlyph
    let pointSize: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> SidebarCompactStatusGlyphImageView {
        SidebarCompactStatusGlyphImageView()
    }

    func updateNSView(_ view: SidebarCompactStatusGlyphImageView, context: Context) {
        view.configure(glyph, pointSize: pointSize, color: color)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SidebarCompactStatusGlyphImageView,
        context: Context
    ) -> CGSize? {
        CGSize(width: pointSize, height: pointSize)
    }
}

/// Glyphs SF Symbols lacks at sidebar size: its pull request and merge
/// symbols are narrow and read as a broken letter at 11 pt. These are drawn
/// in the familiar ring-and-line shape, filling the square. The raw values
/// also work as `sidebar.compactStatusIcons` names.
enum SidebarCompactStatusDrawnGlyph: String {
    case pullRequest = "cmux.pullrequest"
    case merge = "cmux.merge"

    /// A template image `pointSize` square; the caller tints it.
    func image(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            NSColor.black.setStroke()
            path(in: rect).stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Drawn on a 16-unit grid, y down: two rings joined by a line on the
    /// left, then either a line up from a third ring that turns into a
    /// left-pointing arrow (pull request) or a curve into a ring (merge).
    func path(in rect: NSRect) -> NSBezierPath {
        let unit = min(rect.width, rect.height) / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        let radius: CGFloat = 1.9
        let path = NSBezierPath()
        func ring(_ x: CGFloat, _ y: CGFloat) {
            path.appendOval(in: NSRect(
                x: rect.minX + (x - radius) * unit,
                y: rect.minY + (y - radius) * unit,
                width: 2 * radius * unit,
                height: 2 * radius * unit
            ))
        }
        ring(4, 3.2)
        ring(4, 12.8)
        path.move(to: point(4, 3.2 + radius))
        path.line(to: point(4, 12.8 - radius))
        switch self {
        case .pullRequest:
            ring(12, 12.8)
            path.move(to: point(12, 12.8 - radius))
            path.line(to: point(12, 6.2))
            path.curve(to: point(9, 3.2), controlPoint1: point(12, 4.4), controlPoint2: point(10.8, 3.2))
            path.line(to: point(7.2, 3.2))
            path.move(to: point(9.1, 1.3))
            path.line(to: point(7.2, 3.2))
            path.line(to: point(9.1, 5.1))
        case .merge:
            ring(12, 9.5)
            path.move(to: point(4, 3.2 + radius))
            path.curve(to: point(12 - radius, 9.5), controlPoint1: point(4, 8.2), controlPoint2: point(6.5, 9.5))
        }
        path.lineWidth = 1.7 * unit
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
}

import AppKit
import CmuxNextDesign

// The marks of the space switcher (cx-5k3r): each space's icon, emoji or
// initial in its color, the compact dots, and the "+".
extension ProfileBarView {
    /// The mark's opacity: the current space full, others clearly dimmer.
    static func markAlpha(active: Bool, hovered: Bool) -> CGFloat { active ? 1 : (hovered ? 0.9 : 0.7) }

    func draw(profile: SidebarProfile, in rect: NSRect, active: Bool, hovered: Bool, compact: Bool) {
        let color = profileColor(profile, active: active).withAlphaComponent(Self.markAlpha(active: active, hovered: hovered))
        if compact {
            // Too many spaces for full marks: a small dot in the space's color.
            color.setFill()
            let diameter = min(Metrics.roomDotDiameter - 2, rect.width - 2)
            NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                        width: diameter, height: diameter)).fill()
            return
        }
        if let icon = profile.icon, profile.iconIsEmoji {
            let font = NSFont.systemFont(ofSize: min(Metrics.smallIconSize + Metrics.space1, rect.height - Metrics.space2))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = icon.size(withAttributes: attributes)
            // An emoji keeps its own colors, so its opacity is the context's.
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            context?.setAlpha(color.alphaComponent)
            icon.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            context?.restoreGState()
            return
        }
        if let icon = profile.icon,
           let image = NSImage(systemSymbolName: icon, accessibilityDescription: profile.name)?.withSymbolConfiguration(
            // One weight for every state: a selection change never resizes a mark.
            NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize, weight: .regular)
           ) {
            let tinted = image.tinted(color.withAlphaComponent(1))
            let size = tinted.size
            tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                        fraction: color.alphaComponent)
            return
        }
        if let initial = Self.initial(of: profile.name) {
            // No icon: the space's initial in its color (one weight for every
            // state, so a switch never resizes it).
            let font = NSFont.systemFont(ofSize: Metrics.smallIconSize - 1, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = initial.size(withAttributes: attributes)
            initial.draw(at: NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded()),
                         withAttributes: attributes)
            return
        }
        color.setFill()
        let diameter = Metrics.roomDotDiameter
        NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                    width: diameter, height: diameter)).fill()
    }

    /// The first letter of a space's name, uppercased; nil for an empty name.
    static func initial(of name: String) -> String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() }
    }

    /// The space's color, softened toward the strip a little so it sits in
    /// the sidebar chrome (less for the current space, so its color reads).
    // theme-scoped: called only from drawMarks(), inside performWithTheme
    func profileColor(_ profile: SidebarProfile, active: Bool) -> NSColor {
        let base = profile.color?.swatch ?? Palette.textPrimary
        return base.blended(withFraction: active ? 0.05 : 0.2, of: Palette.stripStep) ?? base
    }

    // theme-scoped: called only from drawMarks() inside performWithTheme
    func drawPlus(in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space3, weight: .regular)
        guard let image = NSImage(systemSymbolName: "plus", accessibilityDescription: Strings.newProfile)?.withSymbolConfiguration(config) else { return }
        // Tint opaque, then draw at the dot's alpha: a translucent tint over
        // the black template would stay nearly black.
        let color = Palette.textPrimary.withAlphaComponent(hovered == Self.plusIndex ? 0.6 : 0.35)
        let tinted = image.tinted(color.withAlphaComponent(1))
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: color.alphaComponent)
    }
}

/// One pressable dot for VoiceOver.
nonisolated final class ProfileDotElement: NSAccessibilityElement {
    private let onPress: @MainActor @Sendable () -> Void

    init(label: String, frame: NSRect, parent: Any, onPress: @escaping @MainActor @Sendable () -> Void) {
        self.onPress = onPress
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
    }

    override func accessibilityPerformPress() -> Bool {
        // AppKit calls accessibility actions on the main thread.
        let onPress = onPress
        MainActor.assumeIsolated { onPress() }
        return true
    }
}

/// A non-interactive layer of the bar that draws through `onDraw`.
final class ProfileBarLayerView: NSView {
    var onDraw: ((NSRect) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { onDraw?(dirtyRect) }
}

extension NSImage {
    /// A copy drawn in `color` (symbol images are templates).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

import AppKit
import CmuxNextDesign

/// Click-through shortcut badges shown while a modifier is held: one
/// cmux-classic hint pill per hint (`ShortcutHintChipView`: a Liquid Glass rim
/// around an opaque center, the bordered opaque capsule under Reduce
/// Transparency), right-aligned in its target rect. Text contains only
/// shortcut symbols.
final class ShortcutHintOverlayView: NSView {
    struct Hint: Equatable {
        var text: String
        var rect: CGRect
    }

    var hints: [Hint] = [] {
        didSet { if hints != oldValue { applyHints() } }
    }

    /// Chips are reused while a modifier is held; a release removes them.
    private var badges: [ShortcutHintChipView] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyHints() {
        while badges.count > hints.count { badges.removeLast().removeFromSuperview() }
        while badges.count < hints.count {
            let badge = ShortcutHintChipView()
            addSubview(badge)
            badges.append(badge)
        }
        for (badge, hint) in zip(badges, hints) {
            badge.text = hint.text
            badge.refresh()
            let size = badge.fittingSize
            badge.frame = CGRect(x: hint.rect.maxX - size.width - 2, y: hint.rect.midY - size.height / 2,
                                 width: size.width, height: size.height).integral
        }
    }
}

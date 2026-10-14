public import AppKit
import CmuxNextDesign

/// Click-through shortcut badges shown while a modifier is held: one
/// cmux-classic hint pill per hint (`ShortcutHintChipView`: a Liquid Glass rim
/// around an opaque center, the bordered opaque capsule under Reduce
/// Transparency), right-aligned in its target rect, or in the titlebar row
/// clear of the traffic lights. Text contains only shortcut symbols.
public final class ShortcutHintOverlayView: NSView {
    public struct Hint: Equatable {
        /// Where a chip goes: right-aligned in its target, or in the
        /// titlebar row (centered on its control, kept right of the
        /// traffic lights and of the chip before it, on the traffic
        /// lights' center line).
        public enum Row: Equatable {
            case target
            case titlebar
        }

        public var text: String
        public var rect: CGRect
        public var row: Row

        public init(text: String, rect: CGRect, row: Row = .target) {
            self.text = text
            self.rect = rect
            self.row = row
        }
    }

    public var hints: [Hint] = [] {
        didSet { if hints != oldValue { applyHints() } }
    }

    /// Space between titlebar chips, and after the traffic lights.
    private static let titlebarGap: CGFloat = 4

    /// Chips are reused while a modifier is held; a release removes them.
    private var badges: [ShortcutHintChipView] = []

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyHints() {
        while badges.count > hints.count { badges.removeLast().removeFromSuperview() }
        while badges.count < hints.count {
            let badge = ShortcutHintChipView()
            addSubview(badge)
            badges.append(badge)
        }
        // Titlebar chips are wider than their controls: lay them out left to right.
        var titlebarMaxX = -CGFloat.infinity
        let lights = window.flatMap(WindowTitlebar.trafficLightsFrame(in:)).map { convert($0, from: nil) }
        let ordered = zip(badges, hints).sorted { $0.1.rect.midX < $1.1.rect.midX }
        for (badge, hint) in ordered {
            badge.text = hint.text
            badge.refresh()
            let size = badge.fittingSize
            var origin = CGPoint(x: hint.rect.maxX - size.width - 2, y: hint.rect.midY - size.height / 2)
            if hint.row == .titlebar {
                let floor = max(titlebarMaxX, lights.map { $0.maxX + Self.titlebarGap } ?? -.infinity)
                origin = CGPoint(x: max(hint.rect.midX - size.width / 2, floor),
                                 y: (lights?.midY ?? hint.rect.midY) - size.height / 2)
                titlebarMaxX = origin.x + size.width + Self.titlebarGap
            }
            badge.frame = CGRect(origin: origin, size: size).integral
        }
    }
}

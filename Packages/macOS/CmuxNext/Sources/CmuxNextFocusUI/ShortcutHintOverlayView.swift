public import AppKit
import CmuxNextDesign

/// Click-through shortcut badges shown while Cmd, Ctrl or Option is held:
/// one Liquid Glass chip per hint (`ShortcutHintChipView`; the theme's opaque
/// capsule under Reduce Transparency), right-aligned in its target rect
/// (``Hint/trailingInset`` inside its right edge) and centered on it, or in
/// the titlebar row clear of the traffic lights (their own gap apart, twice
/// it after them). Text contains only
/// shortcut symbols. No hints, no chips: a hold with no matching binding
/// shows nothing. Chips fade in when they appear and fade out when they go
/// (``ShortcutHintChipFading``); a refresh while held moves kept chips without
/// fading them again.
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
        /// What the chip's shortcut selects (`workspace:<id>`), for debug readback; nil when unnamed.
        public var target: String?
        /// How far a `.target` chip's right edge stays inside `rect`'s: 2 pt for a tab or a pane, 0 for a sidebar
        /// row, whose rect is already its content (the trailing mark column's right edge).
        public var trailingInset: CGFloat

        /// Creates a hint.
        ///
        /// - Parameters:
        ///   - text: The shortcut, in symbols.
        ///   - rect: The target, in the overlay's coordinates.
        ///   - row: Where the chip goes.
        ///   - target: What the shortcut selects, for debug readback.
        ///   - trailingInset: The gap between the chip's and `rect`'s right edges (2 pt by default).
        public init(text: String, rect: CGRect, row: Row = .target, target: String? = nil, trailingInset: CGFloat = 2) {
            self.text = text
            self.rect = rect
            self.row = row
            self.target = target
            self.trailingInset = trailingInset
        }
    }

    public var hints: [Hint] = [] {
        didSet { if hints != oldValue { applyHints() } }
    }

    /// Space between titlebar chips when the window shows no traffic lights to measure.
    private static let fallbackTitlebarGap: CGFloat = 6
    /// A target narrower than its chip plus this much gets the chip centered, not trailing.
    private static let narrowTargetSlack: CGFloat = 16

    /// Chips are reused while a modifier is held; a release removes them.
    private var badges: [ShortcutHintChipView] = []
    private let fader: any ShortcutHintChipFading

    /// Creates an empty overlay.
    ///
    /// - Parameter fader: Brings chips in and out; the motion tokens by default.
    public init(fader: any ShortcutHintChipFading = MotionShortcutHintChipFader()) {
        self.fader = fader
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The space between the close and minimize buttons, or nil when they do not show.
    private static func trafficLightGap(in window: NSWindow) -> CGFloat? {
        guard let close = window.standardWindowButton(.closeButton), let mini = window.standardWindowButton(.miniaturizeButton),
              !close.isHidden, !mini.isHidden else { return nil }
        let gap = mini.convert(mini.bounds, to: nil).minX - close.convert(close.bounds, to: nil).maxX
        return gap > 0 ? gap : nil
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyHints() {
        // Leaving chips fade out, then go; kept chips move in place; new chips fade in from clear.
        var leaving: [ShortcutHintChipView] = []
        while badges.count > hints.count { leaving.append(badges.removeLast()) }
        if !leaving.isEmpty {
            let gone = leaving
            fader.fadeOut(gone, in: self) {
                // A chip faded out is never reused (new chips are made), so removing it here is safe.
                for chip in gone { chip.removeFromSuperview() }
            }
        }
        var arriving: [ShortcutHintChipView] = []
        while badges.count < hints.count {
            let badge = ShortcutHintChipView()
            badge.alphaValue = 0
            addSubview(badge)
            badges.append(badge)
            arriving.append(badge)
        }
        defer { if !arriving.isEmpty { fader.fadeIn(arriving, in: self) } }
        // Titlebar chips are wider than their controls: lay them out left to right.
        var titlebarMaxX = -CGFloat.infinity
        let lights = window.flatMap(WindowTitlebar.trafficLightsFrame(in:)).map { convert($0, from: nil) }
        // Titlebar chips keep the lights' own gap between each other and twice it after the lights: at 4 pt their glass
        // edges ran together and crowded the zoom button (Lawrence 2026-10-29: "alignmnet here is generally pretty bad").
        let gap = window.flatMap(Self.trafficLightGap(in:)) ?? Self.fallbackTitlebarGap
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let ordered = zip(badges, hints).sorted { $0.1.rect.midX < $1.1.rect.midX }
        for (badge, hint) in ordered {
            badge.text = hint.text
            badge.refresh()
            let size = badge.fittingSize
            var origin = CGPoint(x: hint.rect.maxX - size.width - hint.trailingInset, y: hint.rect.midY - size.height / 2)
            if hint.row == .target, hint.rect.width < size.width + Self.narrowTargetSlack {
                // An icon tile (Home, the App Store in a tile band) is narrower than a trailing chip: center on it.
                origin.x = hint.rect.midX - size.width / 2
            }
            if hint.row == .titlebar {
                let floor = max(titlebarMaxX, lights.map { $0.maxX + gap * 2 } ?? -.infinity)
                origin = CGPoint(x: max(hint.rect.midX - size.width / 2, floor),
                                 y: (lights?.midY ?? hint.rect.midY) - size.height / 2)
                // Snap up, so rounding never takes back part of the gap.
                origin.x = (origin.x * scale).rounded(.up) / scale
                titlebarMaxX = origin.x + size.width + gap
            }
            // The origin on the nearest backing pixel, the size kept: `integral` grew a chip on a half point by a
            // point and moved its center off its row's (or the lights') line by half a point.
            badge.frame = CGRect(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale,
                                 width: size.width, height: size.height)
        }
    }
}

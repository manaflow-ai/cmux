public import AppKit
public import CmuxNextDesignTokens

/// Hard-edge tech chrome (Debug Settings, `chrome.hardEdge`; Thunderdome round 2 D, Leo
/// 2026-11-05). The game UI of Zenless Zone Zero and Honkai: Star Rail draws panels as layered
/// frames with 45° cuts, diamond markers and thin accent lines; this brings that language to the
/// corner where the sidebar meets the tabs, kept calm enough for a pro tool.
///
/// Every value but `off` draws the same frame: the window is the outer glass frame (one shaded
/// surface across the sidebar, the titlebar row and the tab strip, so the top area is the top bar
/// of everything), and the content below the top tab strip is the inner card, a gap inside it.
/// Nothing in it curves: the card, the selected tab and the selected workspace row each cut their
/// top-leading and bottom-trailing corners at 45°, the one shape of the whole window, so the
/// corner where the sidebar meets the tabs is a straight cut, never a line that bends away into a
/// curve. Compact density keeps today's chrome (Lawrence's ultra compact).
public nonisolated enum HardEdge: String, Sendable, CaseIterable, TunableChoice {
    /// Today's chrome.
    case off
    /// The cuts alone: card, tabs and rows share one chamfered shape on the shaded frame.
    case chamfer
    /// The cuts plus the accent: a lit line along each cut edge and a diamond on the selected
    /// tab and workspace, the ZZZ look.
    case blade
    /// The cuts plus layered frames: a hairline frame inside the gap around the card, parallel to
    /// its cuts, with diamond rivets where it turns, the Star Rail panel look.
    case hud

    public var tunableTitle: String {
        switch self {
        case .off: "Off (today)"
        case .chamfer: "Chamfer (45° cuts, no curves)"
        case .blade: "Blade (cuts with accent lines and diamonds)"
        case .hud: "HUD (layered frames with diamond rivets)"
        }
    }

    public static let tunable = Tunable<HardEdge>.choice(
        "chrome.hardEdge", .sidebar, "Hard-edge chrome",
        help: "Thunderdome r2 D: the content is a chamfered card inside one shaded frame, and the selected tab and workspace take the same 45° cuts. Compact density keeps today's chrome. Off: today's.",
        default: .off, code: "HardEdge.tunable")

    /// The value in effect: the Debug Settings value, except at compact density (`off`).
    @MainActor public static var current: HardEdge {
        Metrics.density == .compact ? .off : tunable.value
    }

    public var isOn: Bool { self != .off }

    // MARK: Geometry

    /// The frame's gap around the card (window edges, the sidebar, under the tab strip): the
    /// glass frame's padding, one and a half grid steps.
    @MainActor public static var gap: CGFloat { Metrics.scale(6) }
    /// The card's large cut (top-leading, beside the sidebar, and bottom-trailing).
    @MainActor public static var cardCut: CGFloat { Metrics.scale(10) }
    /// The card's small cut (the other two corners).
    @MainActor public static var cardMinorCut: CGFloat { Metrics.scale(3) }
    /// A tab's or a row's cut (top-leading and bottom-trailing).
    @MainActor public static var fillCut: CGFloat { Metrics.scale(6) }
    /// A diamond marker's half diagonal.
    @MainActor public static var diamondRadius: CGFloat { Metrics.scale(3) }

    /// The four cuts of a chamfered rect, by corner.
    public struct Cuts: Equatable, Sendable {
        public var topLeading: CGFloat
        public var topTrailing: CGFloat
        public var bottomTrailing: CGFloat
        public var bottomLeading: CGFloat

        public init(topLeading: CGFloat, topTrailing: CGFloat, bottomTrailing: CGFloat, bottomLeading: CGFloat) {
            self.topLeading = topLeading
            self.topTrailing = topTrailing
            self.bottomTrailing = bottomTrailing
            self.bottomLeading = bottomLeading
        }

        /// The signature: a big cut top-leading and bottom-trailing, a small one elsewhere.
        public static func signature(_ major: CGFloat, minor: CGFloat = 0) -> Cuts {
            Cuts(topLeading: major, topTrailing: minor, bottomTrailing: major, bottomLeading: minor)
        }

        /// Mirrored left to right (a sidebar on the right, so the cut faces it).
        public var mirrored: Cuts {
            Cuts(topLeading: topTrailing, topTrailing: topLeading, bottomTrailing: bottomLeading, bottomLeading: bottomTrailing)
        }
    }

    /// The chamfered outline of `rect`, clockwise on screen from the top-leading cut. `flipped`:
    /// y grows downward (a flipped view's layers), so the top is `minY`.
    public static func outline(_ rect: CGRect, cuts: Cuts, flipped: Bool) -> [CGPoint] {
        let limit = min(rect.width, rect.height) / 2
        let tl = min(cuts.topLeading, limit), tr = min(cuts.topTrailing, limit)
        let br = min(cuts.bottomTrailing, limit), bl = min(cuts.bottomLeading, limit)
        let top = flipped ? rect.minY : rect.maxY, bottom = flipped ? rect.maxY : rect.minY
        let down: CGFloat = flipped ? 1 : -1 // from the top edge toward the bottom
        return [
            CGPoint(x: rect.minX + tl, y: top), CGPoint(x: rect.maxX - tr, y: top),
            CGPoint(x: rect.maxX, y: top + down * tr), CGPoint(x: rect.maxX, y: bottom - down * br),
            CGPoint(x: rect.maxX - br, y: bottom), CGPoint(x: rect.minX + bl, y: bottom),
            CGPoint(x: rect.minX, y: bottom - down * bl), CGPoint(x: rect.minX, y: top + down * tl),
        ]
    }

    /// `outline` as a closed path.
    public static func path(_ rect: CGRect, cuts: Cuts, flipped: Bool) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: outline(rect, cuts: cuts, flipped: flipped))
        path.closeSubpath()
        return path
    }

    /// A diamond (a square on its point) centered on `center`.
    public static func diamond(_ center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: center.x, y: center.y - radius), CGPoint(x: center.x + radius, y: center.y),
                                CGPoint(x: center.x, y: center.y + radius), CGPoint(x: center.x - radius, y: center.y)])
        path.closeSubpath()
        return path
    }

    /// The accent of the lit marks: the chosen accent, else the theme's blue, so the marks read as
    /// one hue in a neutral theme too. theme-scoped: call inside the theme scope.
    @MainActor public static var accent: NSColor {
        Palette.hasChosenAccent ? Palette.litGlyph : Palette.highlight
    }

    /// A fill's mask and accent marks (a selected tab or workspace row): the fill clipped to the
    /// signature cut, and under `blade` a lit stroke along the top-leading cut with a diamond at
    /// the leading edge's middle. `rect` is in the layer's flipped coordinates. Returns the mask
    /// path, nil when the value draws no cut.
    @MainActor public func fillMask(_ rect: CGRect) -> CGPath? {
        isOn ? Self.path(rect, cuts: .signature(Self.fillCut), flipped: true) : nil
    }

    /// The lit marks on a selected fill in `rect` (flipped coordinates), as one path to fill with
    /// `accent`, all inside the fill's cut outline so its mask never clips them: `blade` a line
    /// along the top-leading cut that runs on down the leading edge, and one along the
    /// bottom-trailing cut; `hud` a small solid wedge in the top-leading cut. nil otherwise.
    @MainActor public func selectedMarks(_ rect: CGRect) -> CGPath? {
        guard self == .blade || self == .hud, rect.width > 0, rect.height > 0 else { return nil }
        let cut = min(Self.fillCut, rect.width / 2, rect.height / 2)
        let width = Metrics.scale(1.5), step = width * CGFloat(2).squareRoot() // a 45° band `width` thick
        let path = CGMutablePath()
        switch self {
        case .blade:
            // The leading blade: the cut's band, then down the leading edge to the bottom.
            path.addLines(between: [
                CGPoint(x: rect.minX + cut, y: rect.minY), CGPoint(x: rect.minX + cut + step, y: rect.minY),
                CGPoint(x: rect.minX + width, y: rect.minY + cut + step - width), CGPoint(x: rect.minX + width, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY + cut),
            ])
            path.closeSubpath()
            path.addLines(between: [
                CGPoint(x: rect.maxX, y: rect.maxY - cut), CGPoint(x: rect.maxX, y: rect.maxY - cut - step),
                CGPoint(x: rect.maxX - cut - step, y: rect.maxY), CGPoint(x: rect.maxX - cut, y: rect.maxY),
            ])
            path.closeSubpath()
        default:
            let tick = cut + Metrics.scale(4)
            path.addLines(between: [CGPoint(x: rect.minX + cut, y: rect.minY), CGPoint(x: rect.minX + tick, y: rect.minY),
                                    CGPoint(x: rect.minX, y: rect.minY + tick), CGPoint(x: rect.minX, y: rect.minY + cut)])
            path.closeSubpath()
        }
        return path
    }
}

extension Metrics {
    /// What reshapes the main pane's chrome beside its numbers (`WindowRootView.observeMainPane`):
    /// floating panes and the hard-edge value.
    public static var chromeShapeKey: CGFloat {
        CGFloat((floatingPanes ? 1 : 0) + 2 * (HardEdge.allCases.firstIndex(of: HardEdge.current) ?? 0))
    }
}

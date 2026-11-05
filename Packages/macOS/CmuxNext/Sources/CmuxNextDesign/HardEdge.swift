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
/// Nothing in it curves, and every surface has one shape: square on its leading edge, the side
/// toward the sidebar, with its top-trailing corner cut at 45°. The first tab is square and sits
/// on the card's leading edge, so the tab row presses flush on the card instead of a straight
/// line that bends away into a curve (Leo: "the tab at its left ... is just square"); the card,
/// the tabs, the sidebar rows and the + all lean the same way. Compact density keeps today's
/// chrome (Lawrence's ultra compact).
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

    /// The frame's gap around the content host (window edges, the sidebar); the pane padding
    /// inside it adds to the glass frame's padding around the card.
    @MainActor public static var gap: CGFloat { Metrics.scale(4) }
    /// The card's large cut (top-trailing, and its counterweight bottom-leading).
    @MainActor public static var cardCut: CGFloat { Metrics.scale(12) }
    /// The card's small cut (bottom-trailing); the top-leading corner, under the first tab, is square.
    @MainActor public static var cardMinorCut: CGFloat { Metrics.scale(4) }
    /// A tab's, a row's or the +'s top-trailing cut.
    @MainActor public static var fillCut: CGFloat { Metrics.scale(7) }
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

        /// A fill's shape: square but for its top-trailing cut.
        public static func fill(_ cut: CGFloat) -> Cuts {
            Cuts(topLeading: 0, topTrailing: cut, bottomTrailing: 0, bottomLeading: 0)
        }

        /// The card's shape: square top-leading (under the first tab), `major` top-trailing and
        /// bottom-leading, `minor` bottom-trailing.
        public static func card(_ major: CGFloat, minor: CGFloat) -> Cuts {
            Cuts(topLeading: 0, topTrailing: major, bottomTrailing: minor, bottomLeading: major)
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

    /// A fill's mask (a tab, a sidebar row, the +): square but for the top-trailing cut. `rect`
    /// is in flipped coordinates. nil when the value draws no cut.
    @MainActor public func fillMask(_ rect: CGRect) -> CGPath? {
        isOn ? Self.path(rect, cuts: .fill(Self.fillCut), flipped: true) : nil
    }

    /// The lit marks on a selected fill in `rect` (flipped coordinates), as one path to fill with
    /// `accent`, inside the fill's outline so its mask never clips them: `blade` a bar down the
    /// square leading edge (on the first tab, the card's edge continued) and a band along the
    /// top-trailing cut; `hud` a solid wedge in the cut and a diamond on the leading edge. nil otherwise.
    @MainActor public func selectedMarks(_ rect: CGRect) -> CGPath? {
        guard self == .blade || self == .hud, rect.width > 0, rect.height > 0 else { return nil }
        let cut = min(Self.fillCut, rect.width / 2, rect.height / 2)
        let width = Metrics.scale(2), step = width * CGFloat(2).squareRoot() // a 45° band `width` thick
        let path = CGMutablePath()
        switch self {
        case .blade:
            path.addRect(CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
            path.addLines(between: [
                CGPoint(x: rect.maxX - cut, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + cut),
                CGPoint(x: rect.maxX, y: rect.minY + cut + step), CGPoint(x: rect.maxX - cut - step, y: rect.minY),
            ])
            path.closeSubpath()
        default:
            let tick = cut + Metrics.scale(4)
            path.addLines(between: [CGPoint(x: rect.maxX - cut, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + cut),
                                    CGPoint(x: rect.maxX, y: rect.minY + tick), CGPoint(x: rect.maxX - tick, y: rect.minY)])
            path.closeSubpath()
            path.addPath(Self.diamond(CGPoint(x: rect.minX, y: rect.midY), radius: Self.diamondRadius))
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

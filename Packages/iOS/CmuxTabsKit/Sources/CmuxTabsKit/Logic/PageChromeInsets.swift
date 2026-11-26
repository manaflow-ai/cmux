#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// Where the page toolbar sits (`TabsKitTheme.Metrics.barEdge`).
public enum TabsKitBarEdge: Sendable, Equatable {
    /// Safari's bottom toolbar; it hides behind a software keyboard.
    case bottom
    /// Under the status bar; a page's accessory (a composer) owns the bottom edge.
    case top
}

/// How much of the page's top and bottom the status bar and the toolbar cover.
///
/// Two answers. `resting` is the expanded bar's, and never changes while the
/// person scrolls: a surface sized from it (a terminal's grid, a Mac browser's
/// streamed viewport) keeps its size. `live` is where the chrome is this frame:
/// a top bar that collapses into its pill under the status bar gives the band
/// it left back to the page, so what scrolls under the chrome (a transcript's
/// content inset, a web view's, a terminal's status scrim) follows the bar up
/// and the page does not split into a dead strip over a scrolling box
/// (Leo 2026-11-24: "we need to then fix the screens splitting between
/// scrolling and whatnot"). A bottom bar's collapse is unchanged: the page
/// already scrolls under it, Safari's way.
public struct PageChromeInsets: Equatable, Sendable {
    var top: CGFloat
    var bottom: CGFloat

    /// Gap kept between the bar (expanded or collapsed) and the content under it.
    static let contentGap: CGFloat = 8

    /// The top bar's row: just under the status bar (20 pt where a screen reports none,
    /// a landscape phone).
    static func topBarY(safeTop: CGFloat, gap: CGFloat) -> CGFloat {
        max(safeTop, 20) + gap
    }

    /// The collapsed top pill's top: tucked a quarter of its height into the status bar.
    static func collapsedTopPillY(safeTop: CGFloat, pillHeight: CGFloat) -> CGFloat {
        max(0, safeTop - pillHeight / 4)
    }

    /// The expanded top bar's insets: the page starts under the bar's row, and the
    /// bottom is the home indicator's (the accessory's edge).
    static func restingTop(safeTop: CGFloat, safeBottom: CGFloat, gap: CGFloat, control: CGFloat) -> PageChromeInsets {
        PageChromeInsets(top: topBarY(safeTop: safeTop, gap: gap) + control + contentGap, bottom: safeBottom)
    }

    /// Where the chrome covers the page this frame. `resting` is the expanded bar's
    /// (`restingTop` for a top bar, the bottom bar's own for a bottom one).
    static func live(edge: TabsKitBarEdge, collapsed: Bool, resting: PageChromeInsets, safeTop: CGFloat,
                     pillHeight: CGFloat) -> PageChromeInsets {
        guard edge == .top, collapsed else { return resting }
        let pillBottom = collapsedTopPillY(safeTop: safeTop, pillHeight: pillHeight) + pillHeight
        // Never below the resting line: a taller pill than the bar keeps the resting inset.
        return PageChromeInsets(top: min(resting.top, max(safeTop, pillBottom + contentGap)), bottom: resting.bottom)
    }

    /// Whether the accessory row (a composer, a key bar) still rests on the expanded bar's
    /// line. A collapsed bottom bar sinks to its pill and the row follows it down; a collapsed
    /// top bar leaves the bottom where it was, so the row's floor holds there too (without it,
    /// an interactive keyboard dismissal with the top bar collapsed dragged the composer under
    /// its resting place and it jumped back).
    public static func accessoryRestsOnBar(edge: TabsKitBarEdge, collapsed: Bool) -> Bool {
        edge == .top || !collapsed
    }
}

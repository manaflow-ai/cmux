#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// The page's accessory row (a terminal's composer and key row, a chat's
/// bottom stack) during the page <-> grid zoom.
///
/// It is laid out full screen above the toolbar, like the page. While the
/// zoom runs it is drawn through the same full-screen-to-rect mapping as the
/// page (`scale`, then `origin`), so it shrinks into the card with the page
/// and fades out over the first part of the way, all from the zoom's one
/// progress value: reversing or grabbing the zoom moves it with no jump.
struct AccessoryZoom: Equatable, Sendable {
    /// Width of the zoom's rect over the screen's (1 on the page).
    var scale: CGFloat
    /// Where the full-screen layer's top-left corner is drawn.
    var origin: CGPoint
    var opacity: Double
    /// Takes touches (only on the settled page).
    var interactive: Bool
    /// In the accessibility tree (not on the settled grid, where it is invisible).
    var accessible: Bool

    static let identity = AccessoryZoom(scale: 1, origin: .zero, opacity: 1, interactive: true, accessible: true)

    /// Fully faded once the zoom is this far along (the page then is about
    /// two thirds of its width; its card shows no accessory).
    static let fadeEnd = 0.5

    static func presentation(phase: TabZoomState.Phase, progress: Double, offset: CGVector, path: ZoomRectPath) -> AccessoryZoom {
        switch phase {
        case .page:
            return .identity
        case .overview:
            // Kept laid out (opening the page again builds nothing) but
            // invisible, untouchable and out of the accessibility tree.
            return AccessoryZoom(scale: path.card.width / max(1, path.full.width), origin: path.card.origin, opacity: 0,
                                 interactive: false, accessible: false)
        case .animating, .interactive:
            // The page's own rect (raw progress and the pinch's offset, as the
            // page layer draws it), so the row shrinks into the card with it.
            let rect = path.rect(progress: progress, offset: offset)
            let scale = path.full.width > 0 ? max(0.01, rect.width / path.full.width) : 1
            let faded = min(1, max(0, progress / fadeEnd))
            return AccessoryZoom(scale: scale, origin: rect.origin, opacity: 1 - faded, interactive: false, accessible: true)
        }
    }

    static func presentation(_ state: TabZoomState, path: ZoomRectPath) -> AccessoryZoom {
        presentation(phase: state.phase, progress: state.progress, offset: state.offset, path: path)
    }
}

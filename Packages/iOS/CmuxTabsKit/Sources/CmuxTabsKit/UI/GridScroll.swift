#if os(iOS)
import Observation
import SwiftUI

/// The tab grid's scroll position, written on every scroll frame.
///
/// Held by reference so a scroll frame invalidates only the views that read
/// it (the zoom while it runs, `GridFollowOffset`), not the browser screen
/// and every card: as `@State` values on the screen, each scroll frame
/// re-evaluated the screen, the grid and all of its cards (cmux-next device
/// trace: 4 ms of SwiftUI updates per scroll frame, 12 frames over 8 ms).
@MainActor
@Observable
final class GridScrollTracker {
    /// Scroll offset (content offset plus the top inset).
    var offset: CGFloat = 0
    /// The scroll view's top content inset and horizontal content offset
    /// (both 0 for the full-screen grid): with `offset` they place the content.
    var insetTop: CGFloat = 0
    var offsetX: CGFloat = 0

    /// Where content point (0, 0) is on screen now, at the grid's resting
    /// scale. It is the scroll view's own content offset (the grid's scroll
    /// view fills the screen from its origin), never a frame read through
    /// the grid's zoom scale: the grid grows from 1.06 to 1 under the zoom,
    /// and a content frame read through that scale put the zoom's card end
    /// up to 26 pt off its cell and moving, one frame late, until the zoom
    /// ended (Leo, 2026-11-24: "things shift, things lag"). Setting `offset`
    /// moves it at once, so a reveal before the zoom aims at the new slot.
    var screenOrigin: CGPoint { CGPoint(x: -offsetX, y: insetTop - offset) }

    /// A scroll geometry reading: the offset as the grid counts it and the
    /// inset that turns it into the content's screen origin.
    struct Reading: Equatable {
        var offset: CGFloat
        var insetTop: CGFloat
        var offsetX: CGFloat
    }

    func apply(_ r: Reading) {
        if offset != r.offset { offset = r.offset }
        if insetTop != r.insetTop { insetTop = r.insetTop }
        if offsetX != r.offsetX { offsetX = r.offsetX }
    }
}

/// Places a view at `origin`: screen coordinates, or grid content
/// coordinates moved with the grid's scroll when `scroll` is set. Only this
/// modifier reads the scroll position, so the view it wraps (the live
/// page on its card) is not rebuilt on a scroll frame.
struct GridFollowOffset: ViewModifier {
    var origin: CGPoint
    var scroll: GridScrollTracker?

    func body(content: Content) -> some View {
        let base = scroll?.screenOrigin ?? .zero
        content.offset(x: origin.x + base.x, y: origin.y + base.y)
    }
}
#endif

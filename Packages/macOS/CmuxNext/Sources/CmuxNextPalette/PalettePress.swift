import AppKit

/// Press, drag and release, as in a menu: the press selects the row under the pointer, a drag
/// moves the selection with it, and the release runs the row it ends on. A release off every row
/// runs nothing, so a press can be taken back by dragging away.
@MainActor
enum PalettePress {
    /// Tracks one press that began with `event` in `view`. `row` maps a point in `view` to a row
    /// index (nil off every row); `next` supplies the following mouse events, the window's queue
    /// by default.
    static func track(_ event: NSEvent, in view: NSView, row: (NSPoint) -> Int?,
                      select: (Int) -> Void, release: (Int) -> Void,
                      next: (() -> NSEvent?)? = nil) {
        let following = next ?? { [weak window = view.window] in
            window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
        var current: NSEvent? = event
        var selected: Int?
        // Each pass blocks in `nextEvent` until the next drag or the release, which ends it.
        while let event = current {
            let index = row(view.convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseUp {
                if let index { release(index) }
                return
            }
            if let index, index != selected {
                selected = index
                select(index)
            }
            current = following()
        }
    }
}

import AppKit

/// Press, drag and release, as in a menu: the press selects the row under the pointer, a drag
/// moves the selection with it, and the release runs the row it ends on. A release off every row
/// runs nothing, so a press can be taken back by dragging away.
///
/// The panel that owns it takes the press itself (``isOnRow(_:)`` in its `hitTest`) and passes its
/// `mouseDown`, `mouseDragged` and `mouseUp` here, so the press survives the rows being rebuilt
/// under the pointer and no modal loop holds the run loop between the events (Chromium's
/// MenuController follows the drag and runs the item under the release from the widget's own
/// mouse events, ui/views/controls/menu/menu_controller.cc OnMouseDragged and OnMouseReleased).
@MainActor
final class PalettePress {
    /// The view the rows' frames are in.
    private weak var content: NSView?
    private let rows: () -> [NSView]
    private let select: (Int) -> Void
    private let release: (Int) -> Void
    /// The row the press selected last.
    private var selected: Int?
    /// True from a press on a row until its release (or ``cancel()``).
    private(set) var isPressed = false

    /// - Parameters:
    ///   - content: The view whose subviews `rows` returns.
    ///   - rows: The rows shown now, in index order; read at each event, so a rebuild between two
    ///     events is seen.
    ///   - select: The press or a drag reached the row at this index.
    ///   - release: The press ended on the row at this index.
    init(in content: NSView, rows: @escaping () -> [NSView], select: @escaping (Int) -> Void = { _ in },
         release: @escaping (Int) -> Void) {
        self.content = content
        self.rows = rows
        self.select = select
        self.release = release
    }

    /// Whether `hit`, a hit-test result, is a row or inside one: the owning panel answers its
    /// `hitTest` with itself, so the press's drag and release reach it and not a row a rebuild removes.
    func isOnRow(_ hit: NSView?) -> Bool {
        guard let hit else { return false }
        return rows().contains { hit === $0 || hit.isDescendant(of: $0) }
    }

    /// The index of the row under `event`, or nil off every row.
    func index(at event: NSEvent) -> Int? {
        guard let content else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        return rows().firstIndex { $0.frame.contains(point) }
    }

    /// A mouse-down: starts a press when it is on a row, and selects that row. Returns whether it did.
    @discardableResult
    func began(_ event: NSEvent) -> Bool {
        guard index(at: event) != nil else { return false }
        isPressed = true
        selected = nil
        follow(event)
        return true
    }

    /// A mouse-dragged of the press: the selection follows the pointer.
    func dragged(_ event: NSEvent) {
        guard isPressed else { return }
        follow(event)
    }

    /// The press's mouse-up: runs the row it ends on, if any.
    func ended(_ event: NSEvent) {
        guard isPressed else { return }
        cancel()
        if let index = index(at: event) { release(index) }
    }

    /// Drops the press with nothing run (the panel left its window).
    func cancel() {
        isPressed = false
        selected = nil
    }

    private func follow(_ event: NSEvent) {
        guard let index = index(at: event), index != selected else { return }
        selected = index
        select(index)
    }
}

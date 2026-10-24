import AppKit
import CmuxNextCopyMode
import GhosttyNextKit

/// Cmd-hover and Cmd-click on links in one terminal, beyond what Ghostty and
/// ``TerminalPointerMods`` (the keys a pointer event carries) do on their own:
///
/// - Command pressed or released with the pointer still: Ghostty looks again
///   only when the pointer reaches another cell (or, without a program on the
///   mouse, on a key event, which a terminal without focus never gets). Each
///   modifier change, a link filter answer (``TerminalLinkFilter``) and a
///   Cmd-press send the pointer again after an off-grid position that clears
///   Ghostty's last cell, so the first cell the pointer reached shows and opens
///   its link. While the pointer is over this terminal, a modifier watcher
///   (``TerminalModifierMonitor``) reaches it focused or not.
/// - A URL the program broke onto several rows (``TerminalWrappedLink``): every
///   piece is underlined, the pointer is the hand and either row opens the whole
///   URL; Ghostty never sees that press.

@MainActor final class TerminalLinkPointer {
    private weak var view: TerminalSurfaceView?
    /// A Cmd-press on a wrapped link: Ghostty never sees it, the release opens it.
    private var wrappedPress: TerminalWrappedLink?
    /// The wrapped link under the pointer, underlined.
    private(set) var wrapped: TerminalWrappedLink?
    private var wrappedCell: (column: Int, row: Int)?
    private var underlines: [NSView] = []
    private var cursorBeforeWrapped: NSCursor?
    /// The left button is down in this view (from its own press and release, not the
    /// hardware state, which reads up while the release is handled).
    private(set) var isPressing = false
    #if DEBUG
    /// Where a live check's synthetic pointer is, and the keys it holds; the real pointer and
    /// keyboard are elsewhere.
    var testPointer: NSPoint?
    var testFlags: NSEvent.ModifierFlags?
    #endif

    /// Installed while the pointer is over the view.
    private lazy var modifierMonitor = TerminalModifierMonitor { [weak self] flags in self?.modifiersChanged(flags) }

    init(view: TerminalSurfaceView) {
        self.view = view
    }

    // MARK: Modifiers

    /// Command went down or up: look for a link under the still pointer again.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        refresh(flags)
    }

    /// Sends the pointer's position again so Ghostty matches links at it now, even in
    /// the cell it last checked. Never while a button is down (Ghostty would report the
    /// off-grid move as a drag), except for the press Ghostty has not seen yet.
    func refresh(_ flags: NSEvent.ModifierFlags? = nil, at pressPoint: NSPoint? = nil) {
        let flags = flags ?? heldFlags
        guard pressPoint != nil || !buttonsDown, NSEvent.pressedMouseButtons & ~1 == 0 else { return }
        guard let view, let surface = view.surface, let point = pressPoint ?? pointerLocation, view.bounds.contains(point) else { return }
        let mods = GhosttyInput.mods(view.pointerFlags(flags))
        // Off the grid first: Ghostty forgets its last cell (no report: nothing is pressed).
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
        ghostty_surface_mouse_pos(surface, point.x, view.bounds.height - point.y, mods)
        hoverWrapped(at: point, flags: flags, force: true)
    }

    // MARK: Pointer

    /// Whether any button is down: the left one as this view saw it, the others as the hardware says.
    var buttonsDown: Bool { isPressing || NSEvent.pressedMouseButtons & ~1 != 0 }

    /// Command, without Control (Control-click is the context menu).
    static func isLinkChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) && !flags.contains(.control)
    }

    /// The keys held now.
    private var heldFlags: NSEvent.ModifierFlags {
        #if DEBUG
        if let testFlags { return testFlags }
        #endif
        return NSEvent.modifierFlags
    }

    /// The pointer in view coordinates, where it is now.
    private var pointerLocation: NSPoint? {
        #if DEBUG
        if let testPointer { return testPointer }
        #endif
        guard let view else { return nil }
        return view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    }

    /// After a move went to Ghostty.
    func moved(to point: NSPoint, flags: NSEvent.ModifierFlags) {
        modifierMonitor.install()
        guard !buttonsDown else { return }
        hoverWrapped(at: point, flags: flags, force: false)
    }

    func exited() {
        modifierMonitor.remove()
        clearWrapped()
    }

    /// A left press. True: this owns it and Ghostty must not see it.
    func mouseDown(_ event: NSEvent) -> Bool {
        wrappedPress = nil
        isPressing = true
        guard Self.isLinkChord(event.modifierFlags), let view else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        refresh(event.modifierFlags, at: point)
        let hovered = view.session?.model.hoveredLink
        if let wrapped = wrappedLink(at: point), hovered.map({ wrapped.text.contains($0) }) ?? true {
            wrappedPress = wrapped
            return true
        }
        return false
    }

    /// A left release. True: this owned the press.
    func mouseUp(_ event: NSEvent) -> Bool {
        defer { isPressing = false }
        guard let pressed = wrappedPress else { return false }
        wrappedPress = nil
        guard let view else { return true }
        let point = view.convert(event.locationInWindow, from: nil)
        // Released off the link: a cancelled click, as for any link.
        guard let cell = cell(at: point),
              pressed.segments.contains(where: { $0.row == cell.row && (($0.start)...($0.end)).contains(cell.column) }) else { return true }
        _ = view.session?.activateLink(pressed.text)
        return true
    }

    // MARK: Wrapped links

    private func hoverWrapped(at point: NSPoint, flags: NSEvent.ModifierFlags, force: Bool) {
        guard Self.isLinkChord(flags), let cell = cell(at: point) else { return clearWrapped() }
        if !force, let last = wrappedCell, last == cell { return }
        wrappedCell = cell
        guard let link = wrappedLink(at: point) else { return clearWrapped(keepCell: true) }
        guard link != wrapped, let view else { return }
        wrapped = link
        showUnderlines(link)
        if cursorBeforeWrapped == nil { cursorBeforeWrapped = view.cursor }
        view.setCursor(.pointingHand)
    }

    private func clearWrapped(keepCell: Bool = false) {
        if !keepCell { wrappedCell = nil }
        guard wrapped != nil else { return }
        wrapped = nil
        for underline in underlines { underline.removeFromSuperview() }
        underlines.removeAll()
        if let view, let cursor = cursorBeforeWrapped, view.cursor == .pointingHand, view.session?.model.hoveredLink == nil {
            view.setCursor(cursor)
        }
        cursorBeforeWrapped = nil
    }

    private func showUnderlines(_ link: TerminalWrappedLink) {
        for underline in underlines { underline.removeFromSuperview() }
        underlines.removeAll()
        guard let view, let frame = cellFrame() else { return }
        let thickness = max(1, (frame.cellHeight / 16).rounded())
        let color = GhosttyRuntime.shared.copyCursorColor.cgColor
        for segment in link.segments {
            let cells = frame.rect(column: segment.start, row: segment.row, widthCells: segment.end - segment.start + 1)
            let line = NSView(frame: CGRect(x: cells.minX, y: cells.minY + thickness, width: cells.width, height: thickness))
            line.wantsLayer = true
            line.layer?.backgroundColor = color
            view.addSubview(line)
            underlines.append(line)
        }
    }

    /// The wrapped link at `point`, read from the viewport rows around it.
    func wrappedLink(at point: NSPoint) -> TerminalWrappedLink? {
        guard let surface = view?.surface, let cell = cell(at: point) else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics) else { return nil }
        let first = max(0, cell.row - TerminalWrappedLink.reach)
        let last = min(Int(metrics.rows) - 1, cell.row + TerminalWrappedLink.reach)
        guard first <= last else { return nil }
        let rows = (first...last).map { rowText(surface, row: $0, columns: Int(metrics.columns)) }
        return TerminalWrappedLink.find(rows: rows, firstRow: first, columns: Int(metrics.columns), column: cell.column, row: cell.row)
    }

    /// The viewport cell under `point` (view coordinates), or nil off the grid.
    func cell(at point: NSPoint) -> (column: Int, row: Int)? {
        guard let view, let surface = view.surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cell_width > 0, metrics.cell_height > 0 else { return nil }
        let x = point.x - metrics.padding_left, y = view.bounds.height - point.y - metrics.padding_top
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / metrics.cell_width), row = Int(y / metrics.cell_height)
        guard column < Int(metrics.columns), row < Int(metrics.rows) else { return nil }
        return (column, row)
    }

    private func cellFrame() -> CopyModeCursorFrame? {
        guard let view, let surface = view.surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics) else { return nil }
        return CopyModeCursorFrame(cellWidth: metrics.cell_width, cellHeight: metrics.cell_height,
                                   paddingLeft: metrics.padding_left, paddingTop: metrics.padding_top,
                                   viewHeight: view.bounds.height)
    }

    private func rowText(_ surface: ghostty_surface_t, row: Int, columns: Int) -> String {
        guard let y = UInt32(exactly: row), let lastColumn = UInt32(exactly: max(columns - 1, 0)) else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: y),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: lastColumn, y: y),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }
}

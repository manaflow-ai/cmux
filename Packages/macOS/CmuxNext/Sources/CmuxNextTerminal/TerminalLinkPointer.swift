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
/// - A link Ghostty does not find (``TerminalWrappedLink``): a URL a program broke onto
///   rows, or a bare file name that exists (`index.js:57:1`). It gets the hand and an
///   underline on the cells Ghostty does not underline itself (Ghostty underlines a link
///   it found, every row of it, so a second line here would stack on its own), and every
///   piece is underlined, the pointer is the hand and either row opens the whole
///   URL; Ghostty never sees that press.

@MainActor final class TerminalLinkPointer {
    private weak var view: TerminalSurfaceView?
    /// A Cmd-press on a wrapped link: Ghostty never sees it, the release opens it.
    private var wrappedPress: TerminalWrappedLink?
    /// The view hid during such a press: its release, if it still comes, goes nowhere.
    private var swallowsRelease = false
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
        guard let view, view.isShown, let surface = view.surface, let point = pressPoint ?? pointerLocation,
              view.bounds.contains(point) else { return }
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

    /// A move event, which AppKit sends only with no button down: any press this view saw has
    /// ended, even one whose release went elsewhere.
    func movedWithoutButton() {
        isPressing = false
        swallowsRelease = false
    }

    func exited() {
        modifierMonitor.remove()
        isPressing = false
        if wrappedPress != nil { swallowsRelease = true }
        wrappedPress = nil
        clearWrapped()
        #if DEBUG
        testPointer = nil
        testFlags = nil
        #endif
    }

    /// A left press. True: this owns it and Ghostty must not see it.
    func mouseDown(_ event: NSEvent) -> Bool {
        wrappedPress = nil
        isPressing = true
        guard Self.isLinkChord(event.modifierFlags), let view else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        refresh(event.modifierFlags, at: point)
        let hovered = view.session?.model.hoveredLink
        // Ghostty opens a link it found whole itself; this owns only one Ghostty saw a piece of or none.
        guard let link = cmuxLink(at: point, hovered: hovered) else { return false }
        wrappedPress = link
        return true
    }

    /// A left release. True: this owned the press.
    func mouseUp(_ event: NSEvent) -> Bool {
        defer { isPressing = false }
        if swallowsRelease {
            swallowsRelease = false
            return true
        }
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

    /// The shape Ghostty asked for while a link it found was under the pointer.
    private var heldCursor: NSCursor?

    /// Ghostty asked for `cursor` (its `mouse_shape`). True: a link is under the pointer with
    /// Command held (a wrapped one, or one Ghostty found), so the hand stays and `cursor` comes
    /// back when the link goes. A program that turns mouse tracking on or off, or sets its own
    /// pointer shape, otherwise replaces the hand over a link Ghostty underlines.
    func absorbsCursor(_ cursor: NSCursor) -> Bool {
        guard cursor != .pointingHand else { heldCursor = nil; return false }
        if wrapped != nil {
            cursorBeforeWrapped = cursor
            return true
        }
        guard let view, view.session?.model.hoveredLink != nil, view.cursor == .pointingHand,
              Self.isLinkChord(heldFlags) else { return false }
        heldCursor = cursor
        return true
    }

    /// Ghostty reports no link under the pointer now: a shape it asked for meanwhile applies.
    func linkLeft() {
        guard let cursor = heldCursor else { return }
        heldCursor = nil
        if wrapped == nil { view?.setCursor(cursor) }
    }

    // MARK: Wrapped links

    private func hoverWrapped(at point: NSPoint, flags: NSEvent.ModifierFlags, force: Bool) {
        guard Self.isLinkChord(flags), let cell = cell(at: point) else { return clearWrapped() }
        if !force, let last = wrappedCell, last == cell { return }
        wrappedCell = cell
        let hovered = view?.session?.model.hoveredLink
        guard let link = cmuxLink(at: point, hovered: hovered) else { return clearWrapped(keepCell: true) }
        let beside = hovered.map { (link: $0, row: cell.row) }
        guard link != wrapped || beside?.link != underlinedBeside?.link || beside?.row != underlinedBeside?.row, let view else { return }
        wrapped = link
        showUnderlines(link, beside: beside)
        if cursorBeforeWrapped == nil { cursorBeforeWrapped = view.cursor }
        view.setCursor(.pointingHand)
    }

    private func clearWrapped(keepCell: Bool = false) {
        if !keepCell { wrappedCell = nil }
        guard wrapped != nil else { return }
        wrapped = nil
        underlinedBeside = nil
        underlinedRows = []
        for underline in underlines { underline.removeFromSuperview() }
        underlines.removeAll()
        if let view, let cursor = cursorBeforeWrapped, view.cursor == .pointingHand, view.session?.model.hoveredLink == nil {
            view.setCursor(cursor)
        }
        cursorBeforeWrapped = nil
    }

    /// The link Ghostty reported, and the pointer's row, when the underlines were drawn; the rows
    /// they are on.
    private var underlinedBeside: (link: String, row: Int)?
    private(set) var underlinedRows: [Int] = []

    /// Underlines `link` on its rows, except the piece Ghostty found and underlines itself
    /// (`ghostty`: its link under the pointer, on the pointer's row): one line under each cell,
    /// never two. Ghostty's piece of a URL a program broke is on the pointer's row only; it may
    /// end before sentence punctuation the piece keeps, so the texts are compared by overlap.
    private func showUnderlines(_ link: TerminalWrappedLink, beside ghostty: (link: String, row: Int)?) {
        for underline in underlines { underline.removeFromSuperview() }
        underlines.removeAll()
        underlinedBeside = ghostty
        underlinedRows = []
        guard let view, let frame = cellFrame() else { return }
        let thickness = max(1, (frame.cellHeight / 16).rounded())
        let color = GhosttyRuntime.shared.copyCursorColor.cgColor
        let ghosttys = { (segment: TerminalWrappedLink.Segment) in
            guard let ghostty, segment.row == ghostty.row else { return false }
            return ghostty.link.contains(segment.text) || segment.text.contains(ghostty.link)
        }
        for segment in link.segments where !ghosttys(segment) {
            underlinedRows.append(segment.row)
            let cells = frame.rect(column: segment.start, row: segment.row, widthCells: segment.end - segment.start + 1)
            let line = NSView(frame: CGRect(x: cells.minX, y: cells.minY + thickness, width: cells.width, height: thickness))
            line.wantsLayer = true
            line.layer?.backgroundColor = color
            view.addSubview(line)
            underlines.append(line)
        }
    }

    /// The link at `point` that this underlines and opens because Ghostty does not find it
    /// whole (`hovered`: Ghostty's link there): a URL a program broke onto rows, of which
    /// Ghostty has at most a piece, else, where Ghostty has nothing, a bare file name the
    /// terminal's link check says exists. The check runs off the main thread; its answer
    /// sends the pointer again (``TerminalLinkFilter``), which shows the link.
    func cmuxLink(at point: NSPoint, hovered: String?) -> TerminalWrappedLink? {
        guard let view, let surface = view.surface, let cell = cell(at: point) else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics) else { return nil }
        let columns = Int(metrics.columns)
        let first = max(0, cell.row - TerminalWrappedLink.reach)
        let last = min(Int(metrics.rows) - 1, cell.row + TerminalWrappedLink.reach)
        guard first <= last else { return nil }
        let rows = (first...last).map { rowText(surface, row: $0, columns: columns) }
        if let wrapped = TerminalWrappedLink.find(rows: rows, firstRow: first, columns: columns, column: cell.column, row: cell.row),
           wrapped.text != hovered, hovered.map({ wrapped.text.contains($0) }) ?? true {
            return wrapped
        }
        // Without a link check (no app delegate) a dotted word is no file link; nor without a folder
        // the shell reported (a remote shell that reports none would match this Mac's files).
        guard hovered == nil, view.session?.linkCheck != nil, view.session?.model.workingDirectory != nil,
              let word = TerminalWrappedLink.pathWord(in: rows[cell.row - first], columns: columns, column: cell.column, row: cell.row),
              view.bridge.takeUnretainedValue().linkFilter.isLink(word.text) else { return nil }
        return word
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

import AppKit
import CmuxNextCopyMode
import GhosttyNextKit

/// Cmd-hover and Cmd-click on links in one terminal (the view's pointer and
/// modifier events pass through here). Ghostty finds and underlines links,
/// but on its own it misses four cases this fills in:
///
/// - A program that reads the mouse (Claude Code, Codex, vim, htop): Ghostty
///   looks for links only when Shift releases the mouse from the program. With
///   Command held, the pointer goes to Ghostty as Command-Shift; Ghostty drops
///   that Shift again before matching links, so the Command link rules apply,
///   and the press stays out of the program. Mouse reports cannot carry
///   Command, so the program loses nothing it could see.
/// - Command pressed or released with the pointer still: Ghostty looks again
///   only when the pointer reaches another cell (and never for a terminal
///   without focus, which gets no key events). Each modifier change sends the
///   pointer again, after an off-grid position that clears Ghostty's last cell.
///   A link filter answer (``TerminalLinkFilter``) and the press itself do the
///   same, so a click on the first cell the pointer reached opens its link.
/// - Command with Shift or Option (Shift-Command: the other browser; Option-Command:
///   a browser profile): Ghostty matches links only for Command alone, so the pointer
///   carries Command alone while a link is under it; the open reads the real keys.
/// - A URL the program broke onto several rows (``TerminalWrappedLink``): this
///   underlines every piece, shows the pointing hand and opens the whole URL.
@MainActor final class TerminalLinkPointer {
    private unowned let view: TerminalSurfaceView
    /// The press went to Ghostty as a link click; the release must go the same way.
    private var linkPress = false
    /// A Cmd-press on a wrapped link: Ghostty never sees it, the release opens it.
    private var wrappedPress: TerminalWrappedLink?
    /// The wrapped link under the pointer, underlined.
    private(set) var wrapped: TerminalWrappedLink?
    private var wrappedCell: (column: Int, row: Int)?
    private var underlines: [NSView] = []
    private var cursorBeforeWrapped: NSCursor?
    /// Where the last pointer event put the pointer (view coordinates); nil once it left.
    private var pointer: NSPoint?

    init(view: TerminalSurfaceView) {
        self.view = view
        Self.installModifierMonitor()
    }

    // MARK: Modifiers

    /// Command, without Control (Control-click is the context menu).
    static func isLinkChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) && !flags.contains(.control)
    }

    /// What Ghostty gets with a pointer move. `buttonsDown`: a drag that began without
    /// a link goes to the program (or selection) unchanged.
    func moveMods(_ flags: NSEvent.ModifierFlags, buttonsDown: Bool) -> ghostty_input_mods_e {
        guard Self.isLinkChord(flags), !buttonsDown || linkPress else { return GhosttyInput.mods(flags) }
        return linkMods()
    }

    /// What Ghostty gets with a left press or release.
    func buttonMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        linkPress ? linkMods() : GhosttyInput.mods(flags)
    }

    /// Command alone, plus Shift while a program reads the mouse.
    private func linkMods() -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_SUPER.rawValue
        if let surface = view.surface, ghostty_surface_mouse_captured(surface) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    /// Command went down or up: look for a link under the still pointer again.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        refresh(flags)
    }

    /// Sends the pointer's position again so Ghostty matches links at it now, even in
    /// the cell it last checked. Never while a button is down (Ghostty would report the
    /// off-grid move as a drag), except for the press Ghostty has not seen yet.
    func refresh(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags, beforePress: Bool = false) {
        guard beforePress || NSEvent.pressedMouseButtons == 0 else { return }
        guard let surface = view.surface, let point = pointer ?? view.window.map({ view.convert($0.mouseLocationOutsideOfEventStream, from: nil) }),
              view.bounds.contains(point) else { return }
        let mods = moveMods(flags, buttonsDown: false)
        // Off the grid first: Ghostty forgets its last cell (no report: nothing is pressed).
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
        ghostty_surface_mouse_pos(surface, point.x, view.bounds.height - point.y, mods)
        hoverWrapped(at: point, flags: flags, force: true)
    }

    // MARK: Pointer

    /// After a move went to Ghostty.
    func moved(to point: NSPoint, flags: NSEvent.ModifierFlags) {
        pointer = point
        guard NSEvent.pressedMouseButtons == 0 else { return }
        hoverWrapped(at: point, flags: flags, force: false)
    }

    func exited() {
        pointer = nil
        clearWrapped()
    }

    /// A left press. True: this owns it and Ghostty must not see it.
    func mouseDown(_ event: NSEvent) -> Bool {
        linkPress = false
        wrappedPress = nil
        guard Self.isLinkChord(event.modifierFlags) else { return false }
        refresh(event.modifierFlags, beforePress: true)
        let hovered = view.session?.model.hoveredLink
        let point = view.convert(event.locationInWindow, from: nil)
        if let wrapped = wrappedLink(at: point), hovered.map({ wrapped.text.contains($0) }) ?? true {
            wrappedPress = wrapped
            return true
        }
        linkPress = hovered != nil
        return false
    }

    /// A left release. True: this owned the press.
    func mouseUp(_ event: NSEvent) -> Bool {
        defer { linkPress = false }
        guard let pressed = wrappedPress else { return false }
        wrappedPress = nil
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
        guard link != wrapped else { return }
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
        if let cursor = cursorBeforeWrapped, view.cursor == .pointingHand, view.session?.model.hoveredLink == nil {
            view.setCursor(cursor)
        }
        cursorBeforeWrapped = nil
    }

    private func showUnderlines(_ link: TerminalWrappedLink) {
        for underline in underlines { underline.removeFromSuperview() }
        underlines.removeAll()
        guard let frame = cellFrame() else { return }
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
        guard let surface = view.surface, let cell = cell(at: point) else { return nil }
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
        guard let surface = view.surface else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cell_width > 0, metrics.cell_height > 0 else { return nil }
        let x = point.x - metrics.padding_left, y = view.bounds.height - point.y - metrics.padding_top
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / metrics.cell_width), row = Int(y / metrics.cell_height)
        guard column < Int(metrics.columns), row < Int(metrics.rows) else { return nil }
        return (column, row)
    }

    private func cellFrame() -> CopyModeCursorFrame? {
        guard let surface = view.surface else { return nil }
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

    // MARK: Modifier monitor

    private static var monitor: Any?

    /// One app-wide watcher: a modifier change goes to the terminal under the pointer,
    /// which may not have focus (and so gets no key event).
    private static func installModifierMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            // main-proof: local event monitors run on the main thread
            MainActor.assumeIsolated { terminalUnderPointer()?.linkPointer.modifiersChanged(event.modifierFlags) }
            return event
        }
    }

    private static func terminalUnderPointer() -> TerminalSurfaceView? {
        let location = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number), let content = window.contentView else { return nil }
        let point = content.superview?.convert(window.convertPoint(fromScreen: location), from: nil)
            ?? window.convertPoint(fromScreen: location)
        var hit = content.hitTest(point)
        while let view = hit, !(view is TerminalSurfaceView) { hit = view.superview }
        return hit as? TerminalSurfaceView
    }
}


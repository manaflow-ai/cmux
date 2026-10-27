import AppKit
import CmuxNextCopyMode
import CmuxNextTerminalFind
import GhosttyNextKit

// Keyboard copy mode (Toggle Copy Mode, ⇧⌘M): vim keys over the scrollback,
// built on Ghostty's own selection (ghostty-next): a one-cell selection is
// the copy cursor, the binding action `adjust_selection:<move>` moves its
// end and scrolls it into view, `ghostty_surface_select_lines` makes it
// linewise, and `ghostty_surface_selection_end` says where the end is.
// Ghostty tracks the selection through new output. This view resolves keys
// (`CopyModeKeys`), owns the selection kind, draws the cursor box and the
// badge, and copies with `ghostty_surface_copy_selection_to_clipboard_bounded`.

/// One copy-mode session on a surface.
struct CopyModeSession {
    enum Selection { case off, character, line }

    var input = CopyModeInputState()
    var selection = Selection.off
    let cursorBox: NSView
    let badge: TerminalCopyModeBadge
}

/// Keyboard copy mode of one terminal view: owns the session (input
/// state, selection kind, cursor box, badge) and the key-ups it swallowed,
/// and drives Ghostty's keyboard-copy API for the view's surface.
@MainActor
final class TerminalCopyMode {
    unowned let view: TerminalSurfaceView
    /// The copy-mode session while copy mode is on.
    var session: CopyModeSession?
    /// Keys whose key-down copy mode took; their key-up is swallowed too,
    /// also after the key that left copy mode.
    private(set) var consumedKeyUps: Set<UInt16> = []

    init(view: TerminalSurfaceView) {
        self.view = view
    }

    /// Largest selection the copy publishes as rich text (the old app's cap);
    /// plain text is still copied past it.
    static let maximumClipboardBytes: UInt = 2 * 1024 * 1024

    var isActive: Bool { session != nil }

    /// Enters or leaves copy mode. False when the surface cannot enter it.
    @discardableResult
    func toggle() -> Bool {
        if session != nil {
            exit()
            return true
        }
        return enter()
    }

    private func enter() -> Bool {
        // SAFETY: the view's live surface (TerminalSurfaceView.surface), used for this call.
        guard let surface = view.surface, unsafe placeCursorAtTerminalCursor(surface) else { return false }
        // Copy mode swallows keys, so an unfinished IME composition would
        // otherwise sit on screen until it ends.
        view.inputContext?.discardMarkedText()
        view.unmarkText()
        let box = NSView()
        box.wantsLayer = true
        box.layer?.borderWidth = 1
        box.isHidden = true
        let badge = TerminalCopyModeBadge()
        view.addSubview(box)
        badge.pin(toTopTrailingOf: view)
        view.addSubview(badge)
        session = CopyModeSession(cursorBox: box, badge: badge)
        syncCursor()
        return true
    }

    /// Leaves copy mode and clears its selection (and with it the cursor).
    func exit() {
        guard let session else { return }
        self.session = nil
        session.cursorBox.removeFromSuperview()
        session.badge.removeFromSuperview()
        guard let surface = view.surface else { return }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        _ = unsafe ghostty_surface_clear_selection(surface)
    }

    // MARK: Keys

    /// Runs a key-down through copy mode. True when copy mode took it; then
    /// it never reaches the terminal. Command chords pass through so app
    /// shortcuts (Copy, the toggle itself) still work.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard session != nil, let surface = view.surface else { return false }
        let modifiers = CopyModeModifiers(event.modifierFlags)
        if CopyModeKeys.bypassesForShortcut(modifiers) {
            session?.input.reset()
            return false
        }
        consumedKeyUps.insert(event.keyCode)
        // Output or a mouse scroll may have moved the cursor or the selection.
        syncCursor()
        guard var current = session else { return true }
        // Only a key that types a non-ASCII character needs the layout's ASCII map, built once per layout.
        let typesASCII = event.charactersIgnoringModifiers?.unicodeScalars.first?.isASCII ?? true
        let asciiKeys = typesASCII ? ASCIIKeyMap.empty : GhosttyRuntime.shared.inputSources.asciiKeyMap()
        let resolution = CopyModeKeys(asciiCharacter: asciiKeys.character(forKeyCode:)).resolve(
            keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers, hasSelection: current.selection != .off, state: &current.input)
        session?.input = current.input
        guard case .perform(let action, let count) = resolution else { return true }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        unsafe performCopyMode(action, count: count, surface: surface)
        return true
    }

    /// Swallows the key-up of a key copy mode took on key-down.
    func handleKeyUp(_ event: NSEvent) -> Bool {
        consumedKeyUps.remove(event.keyCode) != nil
    }

    private func performCopyMode(_ action: CopyModeAction, count: Int, surface: ghostty_surface_t) {
        switch action {
        case .exit:
            exit()
        case .startSelection:
            // The cursor already is a one-cell selection; it starts growing.
            session?.selection = .character
        case .startLineSelection:
            // SAFETY: every call in this switch passes `surface`, the caller's live surface (the view's).
            unsafe startLineSelection(lines: count, surface: surface)
        case .clearSelection:
            // SAFETY: as above: `surface` is the caller's live surface.
            unsafe collapseToEnd(surface)
            session?.selection = .off
        case .copyAndExit:
            // SAFETY: as above: `surface` is the caller's live surface.
            if unsafe copyModeCopySelection(surface: surface) { exit() }
        case .copyLineAndExit:
            // SAFETY: every call in this switch passes `surface`, the caller's live surface (the view's).
            unsafe startLineSelection(lines: count, surface: surface)
            // SAFETY: as above: `surface` is the caller's live surface.
            if unsafe copyModeCopySelection(surface: surface) { exit() }
        case .scrollLines(let delta):
            // SAFETY: as above: `surface` is the caller's live surface.
            unsafe scroll("scroll_page_lines:\(Self.clampedLines(delta * count))", surface: surface)
        case .scrollPage(let delta):
            // SAFETY: as above: `surface` is the caller's live surface.
            unsafe scroll(delta < 0 ? "scroll_page_up" : "scroll_page_down", times: count, surface: surface)
        case .scrollHalfPage(let delta):
            // SAFETY: as above: `surface` is the caller's live surface.
            unsafe scroll(delta < 0 ? "scroll_page_fractional:-0.5" : "scroll_page_fractional:0.5", times: count, surface: surface)
        case .jumpToPrompt(let delta):
            // SAFETY: as above: `surface` is the caller's live surface.
            unsafe scroll("jump_to_prompt:\(Self.clampedLines(delta * count))", surface: surface)
        case .scrollToTop:
            // SAFETY: as above: `surface` is the caller's live surface.
            unsafe moveCopyModeCursor(.home, count: 1, surface: surface)
        case .scrollToBottom:
            // SAFETY: as above: `surface` is the caller's live surface.
            unsafe moveCopyModeCursor(.end, count: 1, surface: surface)
        case .startSearch:
            // The app's find prompt, the same one ⌘F opens.
            _ = view.handleHostAction(.find)
        case .searchNext:
            for _ in 0..<count { view.session?.navigateSearch(.next) }
        case .searchPrevious:
            for _ in 0..<count { view.session?.navigateSearch(.previous) }
        case .adjustSelection(let move):
            // SAFETY: as above: `surface` is the caller's live surface.
            unsafe moveCopyModeCursor(move, count: count, surface: surface)
        }
        syncCursor()
    }

    // MARK: Ghostty

    /// A one-cell selection at the terminal cursor, scrolled into view.
    private func placeCursorAtTerminalCursor(_ surface: ghostty_surface_t) -> Bool {
        var metrics = ghostty_surface_grid_metrics_s()
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface). Ghostty fills `metrics`, alive for the call.
        guard unsafe ghostty_surface_grid_metrics(surface, &metrics) else { return false }
        if !metrics.cursor_in_viewport {
            _ = view.performBindingAction("scroll_to_bottom")
            // SAFETY: as above.
            guard unsafe ghostty_surface_grid_metrics(surface, &metrics), metrics.cursor_in_viewport else { return false }
        }
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        return unsafe ghostty_surface_select_viewport_cell(surface, metrics.cursor_column, metrics.cursor_row)
    }

    /// The selection's moving end, in viewport cells.
    private func selectionEnd(_ surface: ghostty_surface_t) -> ghostty_surface_selection_end_s? {
        var end = ghostty_surface_selection_end_s()
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface). Ghostty fills `end`, alive for the call.
        return unsafe ghostty_surface_selection_end(surface, &end) ? end : nil
    }

    /// Moves the cursor to the selection's end (no selection grows).
    private func collapseToEnd(_ surface: ghostty_surface_t) {
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        guard let end = unsafe selectionEnd(surface), end.in_viewport, let row = UInt16(exactly: end.row) else { return }
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        _ = unsafe ghostty_surface_select_viewport_cell(surface, end.column, row)
    }

    private func startLineSelection(lines: Int, surface: ghostty_surface_t) {
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        guard unsafe ghostty_surface_select_lines(surface) else { return }
        for _ in 1..<max(1, CopyModeKeys.clampCount(lines)) {
            _ = view.performBindingAction("adjust_selection:down")
        }
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        _ = unsafe ghostty_surface_select_lines(surface)
        session?.selection = .line
    }

    /// Moves the cursor, or the selection's moving end while selecting.
    private func moveCopyModeCursor(_ move: CopyModeMove, count: Int, surface: ghostty_surface_t) {
        for _ in 0..<CopyModeKeys.clampCount(count) {
            _ = view.performBindingAction("adjust_selection:\(move.rawValue)")
        }
        switch session?.selection ?? .off {
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        case .off: unsafe collapseToEnd(surface)
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        case .line: _ = unsafe ghostty_surface_select_lines(surface)
        case .character: break
        }
    }

    /// Scrolls the viewport. Without a selection the cursor stays on screen:
    /// it moves to the nearest visible row in its column.
    private func scroll(_ action: String, times: Int = 1, surface: ghostty_surface_t) {
        for _ in 0..<CopyModeKeys.clampCount(times) { _ = view.performBindingAction(action) }
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        guard session?.selection == .off, let end = unsafe selectionEnd(surface), !end.in_viewport else { return }
        var metrics = ghostty_surface_grid_metrics_s()
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface). Ghostty fills `metrics`, alive for the call.
        guard unsafe ghostty_surface_grid_metrics(surface, &metrics), metrics.rows > 0 else { return }
        let row = end.row < 0 ? 0 : metrics.rows - 1
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        _ = unsafe ghostty_surface_select_viewport_cell(surface, end.column, row)
    }

    private static func clampedLines(_ value: Int) -> Int {
        min(max(value, Int(Int16.min)), Int(Int16.max))
    }

    /// Publishes the selection to the standard clipboard through Ghostty's
    /// clipboard formatter (plain text, plus HTML when it fits).
    private func copyModeCopySelection(surface: ghostty_surface_t) -> Bool {
        // SAFETY: the caller's live surface (the view's, TerminalSurfaceView.surface).
        unsafe ghostty_surface_copy_selection_to_clipboard_bounded(surface, Self.maximumClipboardBytes)
    }

    /// Places the cursor box on the selection's end while nothing is
    /// selected; the box hides while a selection is drawn. A selection the
    /// mouse cleared puts the cursor back at the terminal cursor.
    func syncCursor() {
        guard let session, let surface = view.surface else { return }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        if unsafe !ghostty_surface_has_selection(surface) {
            self.session?.selection = .off
            // SAFETY: the view's live surface (TerminalSurfaceView.surface).
            _ = unsafe placeCursorAtTerminalCursor(surface)
        }
        var metrics = ghostty_surface_grid_metrics_s()
        // SAFETY: the view's live surface (TerminalSurfaceView.surface). Ghostty fills `metrics`, alive for the call.
        guard self.session?.selection == .off,
              let end = unsafe selectionEnd(surface), end.in_viewport,
              unsafe ghostty_surface_grid_metrics(surface, &metrics),
              let frame = CopyModeCursorFrame(cellWidth: metrics.cell_width, cellHeight: metrics.cell_height,
                                              paddingLeft: metrics.padding_left, paddingTop: metrics.padding_top,
                                              viewHeight: view.bounds.height)
        else {
            session.cursorBox.isHidden = true
            return
        }
        session.cursorBox.frame = frame.rect(column: Int(end.column), row: Int(end.row),
                                             widthCells: Int(end.width_cells))
        session.cursorBox.layer?.borderColor = GhosttyRuntime.shared.copyCursorColor.cgColor
        session.cursorBox.isHidden = false
    }
}


extension CopyModeModifiers {
    /// The device-independent flags copy mode matches on.
    init(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: CopyModeModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.numericPad) { modifiers.insert(.numericPad) }
        if flags.contains(.function) { modifiers.insert(.function) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        self = modifiers
    }
}

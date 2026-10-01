public import AppKit
import CmuxNextCopyMode
import GhosttyKit

// Keyboard copy mode (Toggle Copy Mode, ⇧⌘M): vim keys over the scrollback,
// ported from the old app. Ghostty owns the cursor, the selection, and the
// viewport through the cmux fork's keyboard-copy API (ghostty.h:1732-1788);
// this view resolves keys (`CopyModeKeys`), draws the cursor box and the
// badge, and copies with `ghostty_surface_copy_selection_to_clipboard_bounded`.

/// One copy-mode session on a surface.
struct CopyModeSession {
    enum Selection { case off, character, line }

    var input = CopyModeInputState()
    var selection = Selection.off
    let cursorBox: NSView
    let badge: TerminalCopyModeBadge
}

extension TerminalSurfaceView {
    /// Largest selection the copy publishes as rich text (the old app's cap);
    /// plain text is still copied past it.
    static let copyModeMaximumClipboardBytes: UInt = 2 * 1024 * 1024

    public var isCopyModeActive: Bool { copyMode != nil }

    /// Enters or leaves copy mode. False when the surface cannot enter it.
    @discardableResult
    public func toggleCopyMode() -> Bool {
        if copyMode != nil {
            exitCopyMode()
            return true
        }
        return enterCopyMode()
    }

    private func enterCopyMode() -> Bool {
        guard let surface else { return false }
        var column: UInt16 = 0, row: UInt16 = 0, width: UInt16 = 0
        guard ghostty_surface_keyboard_copy_cursor_set(surface, true, &column, &row, &width) else { return false }
        // Copy mode swallows keys, so an unfinished IME composition would
        // otherwise sit on screen until it ends.
        inputContext?.discardMarkedText()
        unmarkText()
        let box = NSView()
        box.wantsLayer = true
        box.layer?.borderWidth = 1
        box.isHidden = true
        let badge = TerminalCopyModeBadge()
        addSubview(box)
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        copyMode = CopyModeSession(cursorBox: box, badge: badge)
        syncCopyModeCursor()
        return true
    }

    /// Leaves copy mode and clears its selection.
    public func exitCopyMode() {
        guard let session = copyMode else { return }
        copyMode = nil
        session.cursorBox.removeFromSuperview()
        session.badge.removeFromSuperview()
        guard let surface else { return }
        _ = ghostty_surface_clear_selection(surface)
        var column: UInt16 = 0, row: UInt16 = 0, width: UInt16 = 0
        _ = ghostty_surface_keyboard_copy_cursor_set(surface, false, &column, &row, &width)
    }

    // MARK: Keys

    /// Runs a key-down through copy mode. True when copy mode took it; then
    /// it never reaches the terminal. Command chords pass through so app
    /// shortcuts (Copy, the toggle itself) still work.
    func handleCopyModeKeyDown(_ event: NSEvent) -> Bool {
        guard copyMode != nil, let surface else { return false }
        let modifiers = CopyModeModifiers(event.modifierFlags)
        if CopyModeKeys.bypassesForShortcut(modifiers) {
            copyMode?.input.reset()
            return false
        }
        copyModeConsumedKeyUps.insert(event.keyCode)
        // Output or a mouse scroll may have moved the cursor or the selection.
        syncCopyModeCursor()
        guard var session = copyMode else { return true }
        let resolution = CopyModeKeys(asciiCharacter: GhosttyInput.asciiCharacter(forKeyCode:)).resolve(
            keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers, hasSelection: session.selection != .off, state: &session.input)
        copyMode?.input = session.input
        guard case .perform(let action, let count) = resolution else { return true }
        performCopyMode(action, count: count, surface: surface)
        return true
    }

    /// Swallows the key-up of a key copy mode took on key-down.
    func handleCopyModeKeyUp(_ event: NSEvent) -> Bool {
        copyModeConsumedKeyUps.remove(event.keyCode) != nil
    }

    private func performCopyMode(_ action: CopyModeAction, count: Int, surface: ghostty_surface_t) {
        switch action {
        case .exit:
            exitCopyMode()
        case .startSelection:
            startCopyModeSelection(linewise: false, lines: 1, surface: surface)
        case .startLineSelection:
            startCopyModeSelection(linewise: true, lines: count, surface: surface)
        case .clearSelection:
            _ = ghostty_surface_clear_selection(surface)
            copyMode?.selection = .off
        case .copyAndExit:
            if copyModeCopySelection(surface: surface) { exitCopyMode() }
        case .copyLineAndExit:
            startCopyModeSelection(linewise: true, lines: count, surface: surface)
            if copyModeCopySelection(surface: surface) { exitCopyMode() }
        case .scrollLines(let delta):
            copyModeScroll(GHOSTTY_KEYBOARD_COPY_SCROLL_LINES, delta * count, surface: surface)
        case .scrollPage(let delta):
            copyModeScroll(GHOSTTY_KEYBOARD_COPY_SCROLL_PAGES, delta * count, surface: surface)
        case .scrollHalfPage(let delta):
            copyModeScroll(GHOSTTY_KEYBOARD_COPY_SCROLL_HALF_PAGES, delta * count, surface: surface)
        case .jumpToPrompt(let delta):
            copyModeScroll(GHOSTTY_KEYBOARD_COPY_SCROLL_PROMPTS, delta * count, surface: surface)
        case .scrollToTop:
            moveCopyModeCursor(.home, count: 1, surface: surface)
        case .scrollToBottom:
            moveCopyModeCursor(.end, count: 1, surface: surface)
        case .startSearch:
            // The app's find prompt, the same one ⌘F opens.
            _ = handleHostAction(.find)
        case .searchNext:
            for _ in 0..<count { searchNext() }
        case .searchPrevious:
            for _ in 0..<count { searchPrevious() }
        case .adjustSelection(let move):
            moveCopyModeCursor(move, count: count, surface: surface)
        }
        syncCopyModeCursor()
    }

    // MARK: Ghostty

    private func startCopyModeSelection(linewise: Bool, lines: Int, surface: ghostty_surface_t) {
        guard let lines = UInt16(exactly: CopyModeKeys.clampCount(lines)) else { return }
        var column: UInt16 = 0, row: UInt16 = 0, width: UInt16 = 0
        guard ghostty_surface_keyboard_copy_selection_start(surface, linewise, lines, &column, &row, &width) else { return }
        copyMode?.selection = linewise ? .line : .character
    }

    /// Moves the cursor, or the selection's moving end while selecting.
    private func moveCopyModeCursor(_ move: CopyModeMove, count: Int, surface: ghostty_surface_t) {
        guard let count = UInt16(exactly: CopyModeKeys.clampCount(count)) else { return }
        let selection = copyMode?.selection ?? .off
        var column: UInt16 = 0, row: UInt16 = 0, width: UInt16 = 0
        _ = ghostty_surface_keyboard_selection_move(surface, Self.ghosttyMove(move), count, selection != .off,
                                                    selection == .line, &column, &row, &width)
    }

    private func copyModeScroll(_ kind: ghostty_keyboard_copy_scroll_e, _ amount: Int, surface: ghostty_surface_t) {
        guard let amount = Int32(exactly: amount) else { return }
        var column: UInt16 = 0, row: UInt16 = 0, width: UInt16 = 0
        _ = ghostty_surface_keyboard_copy_scroll(surface, kind, amount, &column, &row, &width)
    }

    /// Publishes the selection to the standard clipboard through Ghostty's
    /// clipboard formatter (plain text, plus HTML when it fits).
    private func copyModeCopySelection(surface: ghostty_surface_t) -> Bool {
        ghostty_surface_copy_selection_to_clipboard_bounded(surface, Self.copyModeMaximumClipboardBytes)
    }

    /// Places the cursor box from Ghostty's cursor and grid metrics, and
    /// picks up the selection kind Ghostty reports. The box hides while a
    /// selection is drawn.
    func syncCopyModeCursor() {
        guard let session = copyMode, let surface else { return }
        let selection: CopyModeSession.Selection = switch ghostty_surface_keyboard_copy_selection_kind(surface) {
        case GHOSTTY_KEYBOARD_COPY_SELECTION_CHARACTER: .character
        case GHOSTTY_KEYBOARD_COPY_SELECTION_LINE: .line
        default: .off
        }
        copyMode?.selection = selection
        var cursor = ghostty_keyboard_copy_cursor_s()
        var metrics = ghostty_surface_grid_metrics_s()
        guard selection == .off,
              ghostty_surface_keyboard_copy_cursor_snapshot(surface, &cursor),
              ghostty_surface_grid_metrics(surface, &metrics),
              let frame = CopyModeCursorFrame(cellWidth: metrics.cell_width, cellHeight: metrics.cell_height,
                                              paddingLeft: metrics.padding_left, paddingTop: metrics.padding_top,
                                              viewHeight: bounds.height)
        else {
            session.cursorBox.isHidden = true
            return
        }
        session.cursorBox.frame = frame.rect(column: Int(cursor.column), row: Int(cursor.row),
                                             widthCells: Int(cursor.width_cells))
        session.cursorBox.layer?.borderColor = NSColor(
            srgbRed: CGFloat(cursor.color_red) / 255, green: CGFloat(cursor.color_green) / 255,
            blue: CGFloat(cursor.color_blue) / 255, alpha: 1).cgColor
        session.cursorBox.isHidden = false
    }

    private static func ghosttyMove(_ move: CopyModeMove) -> ghostty_keyboard_selection_move_e {
        switch move {
        case .left: GHOSTTY_KEYBOARD_SELECTION_MOVE_LEFT
        case .right: GHOSTTY_KEYBOARD_SELECTION_MOVE_RIGHT
        case .up: GHOSTTY_KEYBOARD_SELECTION_MOVE_UP
        case .down: GHOSTTY_KEYBOARD_SELECTION_MOVE_DOWN
        case .pageUp: GHOSTTY_KEYBOARD_SELECTION_MOVE_PAGE_UP
        case .pageDown: GHOSTTY_KEYBOARD_SELECTION_MOVE_PAGE_DOWN
        case .home: GHOSTTY_KEYBOARD_SELECTION_MOVE_HOME
        case .end: GHOSTTY_KEYBOARD_SELECTION_MOVE_END
        case .beginningOfLine: GHOSTTY_KEYBOARD_SELECTION_MOVE_BEGINNING_OF_LINE
        case .endOfLine: GHOSTTY_KEYBOARD_SELECTION_MOVE_END_OF_LINE
        }
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

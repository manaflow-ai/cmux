import AppKit

/// Selects the auxiliary window that should own a focused-window close shortcut (Cmd+W) among
/// `candidates` (typically the key window, the main window, and the shortcut's event window).
///
/// The close shortcut is a focused-window command, so an auxiliary window may only own it when it is
/// actually the **key** window. A non-key auxiliary candidate — a stale `event.window` that AppKit
/// preserved after another window became key, or a closed-but-reused auxiliary scene (e.g. the
/// Settings window) lingering in the background — must be rejected; otherwise it absorbs Cmd+W and
/// the user's focused window/tab never closes (issue #5321).
///
/// - Parameters:
///   - candidates: Candidate windows in priority order; `nil` entries are skipped.
///   - isAuxiliary: Whether a candidate is an auxiliary cmux window that can own the close shortcut.
///   - isKey: Whether a candidate is currently the key window.
/// - Returns: The first candidate that is both auxiliary and the key window, or `nil` to fall through
///   to the normal focused-window/tab close.
func auxiliaryCloseShortcutTarget<Window>(
    candidates: [Window?],
    isAuxiliary: (Window) -> Bool,
    isKey: (Window) -> Bool
) -> Window? {
    candidates
        .compactMap { $0 }
        .first { isAuxiliary($0) }
}

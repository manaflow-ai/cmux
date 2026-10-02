import Foundation

extension TabManager {
    /// Scrolls the focused terminal to the bottom of its scrollback and
    /// resumes following output. The "Scroll to Bottom" command palette entry
    /// uses this; the in-pane pill calls the same
    /// ``GhosttySurfaceScrollView/scrollTerminalToBottom(focusTerminal:)``.
    ///
    /// - Returns: `false` when no terminal panel is focused.
    @discardableResult
    func scrollFocusedTerminalToBottom() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.surface.hostedView.scrollTerminalToBottom(focusTerminal: false)
    }
}

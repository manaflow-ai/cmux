import AppKit

extension WindowController {
    func startShortcutHints() {
        shortcutHints = WindowShortcutHints(controller: self)
        root.onHintGeometryChange = { [weak self] in self?.shortcutHints?.refresh() }
    }

    /// A key-down hides the hints until release, unless it is a pane-navigation key (the chips follow focus).
    func hideShortcutHintsForKeyDown(_ event: NSEvent) { shortcutHints?.keyDown(event) }

    func stopShortcutHints() {
        shortcutHints?.stop()
        shortcutHints = nil
    }
}

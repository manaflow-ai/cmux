extension WindowController {
    func startShortcutHints() {
        shortcutHints = WindowShortcutHints(controller: self)
        root.onHintGeometryChange = { [weak self] in self?.shortcutHints?.refresh() }
    }

    func hideShortcutHintsForKeyDown() { shortcutHints?.keyDown() }

    func stopShortcutHints() {
        shortcutHints?.stop()
        shortcutHints = nil
    }
}

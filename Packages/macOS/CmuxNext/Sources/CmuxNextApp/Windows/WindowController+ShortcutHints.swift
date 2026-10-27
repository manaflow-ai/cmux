import AppKit

extension WindowController {
    func startShortcutHints() {
        shortcutHints = WindowShortcutHints(controller: self)
        root.onHintGeometryChange = { [weak self] in self?.shortcutHints?.refresh() }
    }

    func stopShortcutHints() {
        shortcutHints?.stop()
        shortcutHints = nil
    }
}

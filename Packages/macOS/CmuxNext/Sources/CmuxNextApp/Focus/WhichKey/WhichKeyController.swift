import AppKit
import CmuxNextActions

/// Shows and hides the which-key overlay with the key router's chord
/// tracker: shown while any chord prefix waits for its next key (the Cmd-J
/// leader, a keybindings.json sequence), hidden as soon as a key runs or
/// dismisses it, focus moves, a click lands, a
/// window closes or the app resigns active. The panel is made on first use.
final class WhichKeyController {
    private var panel: WhichKeyPanel?
    private var isShown = false

    /// Lists `rows`, the keys after the armed `keys`, at the bottom of `window`.
    func show(after keys: [Shortcut], rows: [WhichKeyRow], in window: NSWindow) {
        isShown = true
        let panel = panel ?? WhichKeyPanel()
        self.panel = panel
        panel.present(prefix: keys.flatMap(\.keycaps), rows: rows, on: window)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel?.dismiss()
    }
}

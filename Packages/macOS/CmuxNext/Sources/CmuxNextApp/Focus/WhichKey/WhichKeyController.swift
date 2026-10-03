import AppKit
import CmuxNextActions

/// Shows and hides the which-key overlay with the key router's chord
/// tracker: shown while the Cmd-J leader waits for its second key, hidden
/// as soon as that key runs or dismisses it, focus moves, a click lands, a
/// window closes or the app resigns active. The panel is made on first use.
final class WhichKeyController {
    private unowned let registry: ActionRegistry
    private var panel: WhichKeyPanel?
    private var isShown = false

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// Lists the bindings under `prefix` at the bottom of `window`.
    func show(after prefix: Shortcut, in window: NSWindow) {
        isShown = true
        let panel = panel ?? WhichKeyPanel()
        self.panel = panel
        panel.present(prefix: prefix, rows: WhichKeyListing.rows(after: prefix, in: registry), on: window)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel?.dismiss()
    }
}

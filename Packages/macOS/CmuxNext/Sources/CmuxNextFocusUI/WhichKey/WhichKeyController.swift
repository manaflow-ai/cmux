public import AppKit
public import CmuxNextActions

/// Shows and hides the which-key overlay with the key router's chord
/// tracker: shown while any chord prefix waits for its next key (the Cmd-J
/// leader, a keybindings.json sequence), hidden as soon as a key runs or
/// dismisses it, focus moves, a click lands, a
/// window closes or the app resigns active. The overlay is made on first use.
public final class WhichKeyController {
    private var overlay: WhichKeyOverlay?
    private var isShown = false

    public init() {}

    /// Lists `rows`, the keys after the armed `keys`, at the bottom of `window`.
    public func show(after keys: [Shortcut], rows: [WhichKeyRow], in window: NSWindow) {
        isShown = true
        let overlay = overlay ?? WhichKeyOverlay()
        self.overlay = overlay
        overlay.present(prefix: keys.flatMap(\.keycaps), rows: rows, on: window)
    }

    public func hide() {
        guard isShown else { return }
        isShown = false
        overlay?.dismiss()
    }
}

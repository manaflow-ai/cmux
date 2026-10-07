import AppKit
import Carbon.HIToolbox
import GhosttyNextKit

/// Secure keyboard entry requested by Ghostty (`GHOSTTY_ACTION_SECURE_INPUT`,
/// for example a password prompt with `macos-auto-secure-input`).
enum TerminalSecureInput {
    private static var enabledViews: Set<ObjectIdentifier> = []

    static func apply(_ mode: ghostty_action_secure_input_e, for view: TerminalSurfaceView) {
        let id = ObjectIdentifier(view)
        let wasEnabled = !enabledViews.isEmpty
        switch mode {
        case GHOSTTY_SECURE_INPUT_ON: enabledViews.insert(id)
        case GHOSTTY_SECURE_INPUT_OFF: enabledViews.remove(id)
        default:
            if enabledViews.contains(id) { enabledViews.remove(id) } else { enabledViews.insert(id) }
        }
        let isEnabled = !enabledViews.isEmpty
        guard isEnabled != wasEnabled else { return }
        if isEnabled { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }

    static func release(_ view: TerminalSurfaceView) {
        guard enabledViews.remove(ObjectIdentifier(view)) != nil, enabledViews.isEmpty else { return }
        DisableSecureEventInput()
    }
}

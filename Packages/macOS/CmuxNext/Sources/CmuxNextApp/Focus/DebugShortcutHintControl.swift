#if DEBUG
import AppKit
import CmuxNextSettings

/// Drives the real modifier monitor for captures when the GUI driver cannot hold keys.
@MainActor
struct DebugShortcutHintControl {
    // AppKit event delivery and the window monitor require main-actor execution.
    func handle(_ params: [String: JSONValue], services: AppServices?) async -> JSONValue {
        guard let services,
              let controller = services.windows.active,
              let hints = controller.shortcutHints else {
            return .object(["error": .string("no active window hint monitor")])
        }
        let flags: NSEvent.ModifierFlags
        switch params["modifier"]?.stringValue {
        case "cmd": flags = .command
        case "ctrl": flags = .control
        case "release": flags = []
        default: return .object(["error": .string("modifier must be cmd, ctrl, or release")])
        }
        let ready = await hints.debugHold(flags)
        return .object(["ready": .bool(ready), "released": .bool(flags.isEmpty),
                        "source": .string("modifier held via debug event injection")])
    }
}
#endif

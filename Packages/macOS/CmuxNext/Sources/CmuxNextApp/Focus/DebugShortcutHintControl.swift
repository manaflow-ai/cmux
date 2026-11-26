#if DEBUG || CMUX_BENCH_HOOKS
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
        // "cmd", "ctrl", "opt", "shift" joined by "+" (for example "ctrl+opt"), or "release".
        let names: [String: NSEvent.ModifierFlags] = ["cmd": .command, "ctrl": .control, "opt": .option, "shift": .shift, "release": []]
        let parts = (params["modifier"]?.stringValue ?? "").split(separator: "+").map { names[String($0)] }
        guard !parts.isEmpty, !parts.contains(nil), parts.count == 1 || !parts.contains(where: { $0?.isEmpty == true }) else { return .object(["error": .string("modifier must be cmd, ctrl, opt, shift joined by +, or release")]) }
        let flags = parts.reduce(into: NSEvent.ModifierFlags()) { $0.formUnion($1 ?? []) }
        let ready = await hints.debugHold(flags)
        let shown = hints.shownHints.map { JSONValue.object(["text": .string($0.text), "target": $0.target.map(JSONValue.string) ?? .null]) }
        return .object(["ready": .bool(ready), "released": .bool(flags.isEmpty), "hints": .array(shown),
                        "source": .string("modifier held via debug event injection")])
    }
}
#endif

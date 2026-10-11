#if DEBUG
import CmuxNextControl
import CmuxNextSettings

/// `debug.hints` (DEBUG builds): whether hint mode shows, what is typed, and
/// each label with its control (role, title, window rect), for
/// scripts/cmux-next/hint-mode-e2e.py.
@MainActor
enum DebugHints {
    static func report(_ hints: WindowHintController) -> JSONValue {
        guard let shown = hints.shown else { return ["active": false, "typed": "", "hints": []] }
        return [
            "active": true,
            "typed": .string(shown.typed),
            "hints": .array(shown.hints.map { hint in
                let rect = hint.target.rect
                return [
                    "label": .string(hint.label), "role": .string(hint.target.role), "title": .string(hint.target.title),
                    "x": .number(Double(rect.minX)), "y": .number(Double(rect.minY)),
                    "width": .number(Double(rect.width)), "height": .number(Double(rect.height)),
                ]
            }),
        ]
    }
}
#endif

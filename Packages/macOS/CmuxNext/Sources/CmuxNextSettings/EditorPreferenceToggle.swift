import Foundation

/// A code editor page toggle (PAGE-PREFS): the action that flips an `editor.*` setting the page
/// toolbar also writes (Word Wrap, Minimap). The App binds each; the page follows its look. The
/// toggles and what each writes live in Rust (`editor_toggle.all`, `editor_toggle.next`).
public struct EditorPreferenceToggle: Sendable {
    /// The catalog action.
    public let action: String
    /// The setting key the toggle writes (`editor.minimap.enabled`).
    public let key: String

    /// Every toggle, in the page toolbar's order.
    public static let all: [EditorPreferenceToggle] = (SettingsRust.answer("editor_toggle.all", [:])["toggles"]?.arrayValue ?? [])
        .compactMap { toggle in
            guard let action = toggle["action"]?.stringValue, let key = toggle["key"]?.stringValue else { return nil }
            return EditorPreferenceToggle(action: action, key: key)
        }

    /// Opt-Z: `editor.wordWrap` between "off" and "on" (any other mode counts as on).
    public static var wordWrap: EditorPreferenceToggle { named("toggleFileEditorWordWrap") }

    /// Toggle Editor Minimap: `editor.minimap.enabled`, read as `true`/`false` or Monaco's `{enabled}` form.
    public static var minimap: EditorPreferenceToggle { named("toggleFileEditorMinimap") }

    private static func named(_ action: String) -> EditorPreferenceToggle {
        all.first { $0.action == action } ?? EditorPreferenceToggle(action: action, key: "")
    }

    /// The value the toggle writes when the page's editor section is `section`.
    public func next(in section: JSONValue?) -> JSONValue {
        SettingsRust.answer("editor_toggle.next", ["action": .string(action), "section": section ?? .null])["value"] ?? .null
    }
}

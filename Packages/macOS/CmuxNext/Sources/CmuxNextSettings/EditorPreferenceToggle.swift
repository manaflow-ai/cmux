import Foundation

/// A code editor page toggle (PAGE-PREFS): the action that flips an `editor.*` setting the page
/// toolbar also writes (Word Wrap, Minimap). The App binds each; the page follows its look.
public struct EditorPreferenceToggle: Sendable {
    /// The catalog action.
    public let action: String
    /// The setting key the toggle writes (`editor.minimap.enabled`).
    public let key: String
    private let flip: @Sendable (JSONValue?) -> JSONValue

    /// Opt-Z: `editor.wordWrap` between "off" and "on" (any other mode counts as on).
    public static let wordWrap = EditorPreferenceToggle(action: "toggleFileEditorWordWrap", key: "editor.wordWrap") { section in
        .string((section?["wordWrap"]?.stringValue ?? "off") == "off" ? "on" : "off")
    }

    /// Toggle Editor Minimap: `editor.minimap.enabled`, read as `true`/`false` or Monaco's `{enabled}` form.
    public static let minimap = EditorPreferenceToggle(action: "toggleFileEditorMinimap", key: "editor.minimap.enabled") { section in
        let minimap = section?["minimap"]
        return .bool(!(minimap?.boolValue ?? minimap?["enabled"]?.boolValue ?? false))
    }

    public static let all = [wordWrap, minimap]

    /// The value the toggle writes when the page's editor section is `section`.
    public func next(in section: JSONValue?) -> JSONValue { flip(section) }
}

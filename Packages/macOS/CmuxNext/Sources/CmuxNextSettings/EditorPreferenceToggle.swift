public import CmuxNextActions
import Foundation

/// A code editor page toggle (PAGE-PREFS): the action that flips an `editor.*` setting the page
/// toolbar also writes (Word Wrap, Minimap). The App binds each; the page follows its look.
public struct EditorPreferenceToggle: Sendable {
    /// The catalog action.
    public let action: String
    /// The setting key the toggle writes (`editor.minimap.enabled`).
    public let key: String
    private let read: @Sendable (JSONValue?) -> Bool
    private let write: @Sendable (Bool) -> JSONValue

    /// Opt-Z: `editor.wordWrap` between "off" and "on" (any other mode counts as on).
    public static let wordWrap = EditorPreferenceToggle(action: "toggleFileEditorWordWrap", key: "editor.wordWrap",
                                                        read: { ($0?["wordWrap"]?.stringValue ?? "off") != "off" },
                                                        write: { .string($0 ? "on" : "off") })

    /// Toggle Editor Minimap: `editor.minimap.enabled`, read as `true`/`false` or Monaco's `{enabled}` form.
    public static let minimap = EditorPreferenceToggle(action: "toggleFileEditorMinimap", key: "editor.minimap.enabled",
                                                       read: { section in
                                                           let minimap = section?["minimap"]
                                                           return minimap?.boolValue ?? minimap?["enabled"]?.boolValue ?? false
                                                       },
                                                       write: { .bool($0) })

    public static let all = [wordWrap, minimap]

    /// Whether the setting is on when the page's editor section is `section` (the palette row's state).
    public func isOn(in section: JSONValue?) -> Bool { read(section) }

    /// The value the toggle writes when the page's editor section is `section`.
    public func next(in section: JSONValue?) -> JSONValue { write(!read(section)) }

    /// Makes the toggle's palette row show whether the setting is on now.
    ///
    /// - Parameters:
    ///   - registry: The registry the toggle's action is bound in.
    ///   - section: The code editor's `editor` settings section now; it runs on every palette open,
    ///     so it must be cheap and must not refuse.
    @MainActor
    public func bindPaletteState(into registry: ActionRegistry, section: @escaping @MainActor () -> JSONValue?) {
        ActionTargetTitles.setPaletteState(ActionID(rawValue: action), in: registry) { isOn(in: section()) }
    }
}

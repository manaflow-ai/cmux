/// `developerTools.appPages` in cmux-next.json: whether cmux's own pages (an agent chat, Home,
/// Markdown, Settings) open developer tools: Inspect Element in their right-click menu, and Toggle
/// Developer Tools, Inspect Element and the palette's Developer Tools commands. On by default in
/// every build; browser tabs keep their developer tools either way.
///
/// Read from the snapshot's document, not stored: only a literal `false` turns it off.
public nonisolated struct AppPageDevToolsSetting: Sendable {
    // `configPath` and `fallback` (on) are generated from schemas/settings/source/developer-tools.json.

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: off only for a literal `false`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.configPath)?.boolValue ?? Self.fallback
    }
}

/// `app.internalDeveloperMode` in cmux-next.json: whether the person's Command Palette lists the
/// debug-only actions ("Debug: <name>" rows; `DebugActionGate`). Off by default; a row in Settings >
/// Development, which DEV and NIGHTLY builds show. Release and RC builds have no debug actions, so it
/// does nothing there. Scripts run debug actions in DEV and NIGHTLY whatever it is.
///
/// Read from the snapshot's document, not stored: only a literal `true` turns it on.
public nonisolated struct InternalDeveloperModeSetting: Sendable {
    // `configPath` and `fallback` (off) are generated from schemas/settings/source/developer-tools.json.

    /// Makes the value from its parts.
    public init() {}

    /// The value in `root`: on only for a literal `true`.
    public func value(in root: JSONValue) -> Bool {
        root.value(at: Self.configPath)?.boolValue ?? Self.fallback
    }
}

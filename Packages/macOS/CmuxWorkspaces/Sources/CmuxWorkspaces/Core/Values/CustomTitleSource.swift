/// Who set a custom title.
///
/// Auto-naming (AI-generated titles) must never overwrite a user-set title;
/// this enum carries that distinction for workspace and panel custom titles,
/// and round-trips through session persistence. The raw values (`"user"` /
/// `"auto"`) are a persistence/wire format carried in session snapshots, so
/// they are frozen. Formerly `Workspace.CustomTitleSource`, kept reachable at
/// that spelling by a nested `typealias` so every `Workspace.CustomTitleSource`
/// call site and the `Codable` snapshot fields stay byte-identical.
public enum CustomTitleSource: String, Codable, Sendable {
    /// A manual rename (sidebar, CLI, command palette).
    case user
    /// An AI auto-naming write.
    case auto
}

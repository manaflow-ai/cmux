/// Where a link or path the person opens from a pane lands (`layout.linkPlacement` in cmux.json):
/// a URL, a file path, a `cmux://` link clicked in a terminal, an agent chat, Home, a Markdown or
/// code page. The source pane keeps showing what it showed.
///
/// ```jsonc
/// "layout": { "linkPlacement": "split-right" }   // "new-column", "same-pane"
/// ```
public nonisolated enum LinkPlacement: String, Hashable, Sendable, CaseIterable {
    /// The pane right of the source pane, as a new tab; with no pane there, a new split on the
    /// source pane's right. The default: the source stays in view beside what it opened.
    case splitRight = "split-right"
    /// Same as ``splitRight``, but with no pane on the right a new column opens right of the
    /// source pane's column instead of a split.
    case newColumn = "new-column"
    /// A new tab in the source pane (cmux-next before 2026-10-19).
    case samePane = "same-pane"

    /// The cmux.json key.
    public static let configPath = ["layout", "linkPlacement"]
    /// ``splitRight`` when the key is unset or invalid.
    public static let fallback: LinkPlacement = .splitRight
}

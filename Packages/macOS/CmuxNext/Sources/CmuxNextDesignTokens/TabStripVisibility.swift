/// When a pane shows its tab strip (cmux.json `tabs.stripVisibility`). Rust decides each pane
/// (`cmux_window_rules::tabs::panes::strip`, `WindowRules.strip`); the raw values are its wire names.
/// `auto` (the default) is the strip in every pane with `tabs.hideLoneChatTab` honoured; `always` shows
/// a lone chat's tab too; `whenMultiple` hides the whole row of a pane with one tab; `never` hides every
/// pane's strip, as a chat-first app does. A pane's own Show Tab Bar or Hide Tab Bar wins over each.
public nonisolated enum TabStripVisibility: String, Hashable, Sendable, CaseIterable, Codable {
    case auto
    case always
    case whenMultiple
    case never
}

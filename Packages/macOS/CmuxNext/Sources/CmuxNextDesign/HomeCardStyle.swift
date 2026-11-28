/// `appearance.homeCardStyle`: how the cards on Home and the New Tab page draw (the recent chats' cards, the
/// environment and suggestions cards over the composer, the Home lists under a new chat's composer). Leo,
/// 2026-11-19: "you guys should be customizing the tabs/sidebars a lot deeper too. prob likewise the session info
/// and the top right buttons as well"; a theme file sets it like every `appearance.*` look key.
///
/// - `standard` (the default): today's cards, unchanged.
/// - `flat`: a tonal fill, no edge and no shadow.
/// - `raised`: an elevated card with a hairline and a soft shadow.
/// - `glass`: see-through cards with a rim over the window's picture.
///
/// The cards are web (webviews `newtab/screen.css`, `styles.css`); the value reaches the page with the pane's theme
/// (`AgentPaneTheme.values`, `homeCardStyle`), which sets `data-home-cards` on the page's root, so a change applies
/// live with no reload.
public nonisolated enum HomeCardStyle: String, Sendable, CaseIterable, Codable {
    case standard
    case flat
    case raised
    case glass
}

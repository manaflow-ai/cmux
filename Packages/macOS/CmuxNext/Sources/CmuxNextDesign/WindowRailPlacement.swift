/// `window.rail` in cmux.json: whether the sidebar's sticky sections show
/// as an icon rail, and where it sits. At the leading edge by default.
public nonisolated enum WindowRailPlacement: String, Sendable, CaseIterable, Codable {
    /// No rail: the sidebar shows its sticky sections itself.
    case off
    /// At the window's leading edge, before the sidebar (the default, like
    /// the Codex app's skinny strip); the sidebar becomes an inset panel.
    case leading
    /// Between the sidebar and the content column.
    case afterSidebar
}

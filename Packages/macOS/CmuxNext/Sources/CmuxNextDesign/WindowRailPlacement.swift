/// `window.rail` in cmux.json: whether the sidebar's sticky sections show
/// as an icon rail, and where it sits. Off by default.
public nonisolated enum WindowRailPlacement: String, Sendable, CaseIterable, Codable {
    /// No rail (the default): the window is laid out as without one.
    case off
    /// At the window's leading edge, before the sidebar.
    case leading
    /// Between the sidebar and the content column.
    case afterSidebar
}

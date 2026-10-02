/// `window.rail` in cmux.json: where the window's icon rail (new terminal,
/// browser and agent chat, notifications, history, accounts) sits. A
/// prototype for comparing the two placements.
public nonisolated enum WindowRailPlacement: String, Sendable, CaseIterable, Codable {
    /// No rail (the default): the window is laid out as without one.
    case off
    /// At the window's leading edge, before the sidebar.
    case leading
    /// Between the sidebar and the content column.
    case afterSidebar
}

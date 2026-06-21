import Foundation

/// Which Dock the right-sidebar Dock panel is presenting.
///
/// The Dock panel can show two distinct Bonsplit trees, chosen by a toggle in
/// the Dock toolbar and persisted in `FileExplorerState`:
///
/// - ``workspace``: the per-workspace Dock, seeded from the project
///   `.cmux/dock.json` resolved upward from that workspace's directory. Its live
///   panels (terminals/browsers) belong to the workspace and are torn down when
///   the workspace closes.
/// - ``global``: a single app-wide Dock, seeded from `~/.config/cmux/dock.json`
///   with a home base directory. Its live panels persist across every workspace
///   and window for the lifetime of the app.
enum DockScope: String, CaseIterable, Codable, Sendable {
    case workspace
    case global

    /// Short label shown on the Dock toolbar scope toggle.
    var label: String {
        switch self {
        case .workspace:
            return String(localized: "dock.scope.workspace", defaultValue: "Workspace")
        case .global:
            return String(localized: "dock.scope.global", defaultValue: "Global")
        }
    }

    /// SF Symbol used to represent the scope on compact controls.
    var symbolName: String {
        switch self {
        case .workspace: return "macwindow"
        case .global: return "globe"
        }
    }
}

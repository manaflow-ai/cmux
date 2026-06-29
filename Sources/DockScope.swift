import Foundation

/// Which Dock backing store a `DockSplitStore` uses.
///
/// - ``workspace``: the legacy per-workspace Dock, seeded from the project
///   `.cmux/dock.json` resolved upward from that workspace's directory. Its live
///   panels (terminals/browsers) belong to the workspace and are torn down when
///   the workspace closes.
/// - ``global``: a single app-wide Dock, seeded from `~/.config/cmux/dock.json`
///   with a home base directory. Its live panels persist across every workspace
///   and window for the lifetime of the app.
enum DockScope: String, Codable, Sendable {
    case workspace
    case global
}

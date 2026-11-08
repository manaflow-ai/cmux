import Foundation

/// Which Dock backing store a `DockSplitStore` uses.
///
/// - ``workspace``: the legacy per-workspace Dock, seeded from the project
///   `.cmux/dock.json` resolved upward from that workspace's directory. Its live
///   panels (terminals/browsers) belong to the workspace and are torn down when
///   the workspace closes.
/// - ``global``: a per-window Dock, seeded from the global config at
///   `~/.config/cmux/dock.json` with a home base directory. Each main window
///   owns one (see `AppDelegate.windowDock(forWindowId:)`); its live panels
///   persist across that window's workspaces and are torn down with the window.
///   (The case name reflects the config source, not instance cardinality; the
///   raw value is kept stable for coding compatibility.)
enum DockScope: String, Codable, Sendable {
    case workspace
    case global
}

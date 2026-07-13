/// The kind of surface a Dock pane hosts. The Dock reuses the main-area panel
/// system, so it supports the same first-class pane kinds: terminals and
/// browsers.
enum DockSurfaceKind: String, Codable, Equatable, Sendable {
    case terminal
    case browser
}

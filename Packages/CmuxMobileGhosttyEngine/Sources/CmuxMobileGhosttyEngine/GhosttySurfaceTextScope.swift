/// Which region of a terminal surface a text read covers.
///
/// Mirrors libghostty's `ghostty_point_tag_e` without exposing the C type, so
/// callers outside this package never import GhosttyKit.
public enum GhosttySurfaceTextScope: Sendable, CaseIterable {
    /// The visible viewport grid (no scrollback).
    case viewport
    /// The full screen buffer.
    case screen
    /// The active screen area.
    case active
    /// The whole surface.
    case surface
}

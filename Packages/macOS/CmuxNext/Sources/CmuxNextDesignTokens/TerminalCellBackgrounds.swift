/// `appearance.terminalCellBackgrounds`: how a program's explicit cell backgrounds (SGR 4x/48, a
/// TUI's message band or status line) draw over a translucent window or wallpaper
/// (`GhosttyRuntimeSurfacePolicy.cellBackgroundLines`).
public nonisolated enum TerminalCellBackgrounds: String, CaseIterable, Sendable {
    /// Fully opaque, as Ghostty draws them (the default; loads nothing).
    case opaque
    /// At the window's opacity, while the window is translucent or see-through.
    case window
    /// Greys that differ from the theme background only in lightness fade toward transparent.
    case tint
    /// Both `tint` and `window`.
    case tintWindow
}

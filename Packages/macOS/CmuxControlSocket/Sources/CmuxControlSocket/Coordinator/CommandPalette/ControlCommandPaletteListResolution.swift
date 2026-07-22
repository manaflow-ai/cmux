/// The app-side outcome of enumerating the actions available through
/// Cmd+Shift+P in one window.
public enum ControlCommandPaletteListResolution: Sendable, Equatable {
    /// No live main window matched the routing selectors.
    case windowNotFound
    /// The live palette actions and their immutable target were resolved.
    case listed(target: ControlCommandPaletteTarget, commands: [ControlCommandPaletteItem])
}

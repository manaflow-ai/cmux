/// The app-side outcome of enumerating the actions available through
/// Cmd+Shift+P in one window.
public enum ControlCommandPaletteListResolution: Sendable, Equatable {
    /// No live main window matched the routing selectors.
    case windowNotFound
    /// The target is live, but its detached config snapshot is still loading.
    case configurationPending
    /// The live palette actions and their immutable target were resolved.
    case listed(target: ControlCommandPaletteTarget, commands: [ControlCommandPaletteItem])
}

public import Foundation

/// The app-side outcome of enumerating the actions available through
/// Cmd+Shift+P in one window.
public enum ControlCommandPaletteListResolution: Sendable, Equatable {
    /// No live main window matched the routing selectors.
    case windowNotFound
    /// The live palette actions were resolved for the window.
    case listed(windowID: UUID, commands: [ControlCommandPaletteItem])
}

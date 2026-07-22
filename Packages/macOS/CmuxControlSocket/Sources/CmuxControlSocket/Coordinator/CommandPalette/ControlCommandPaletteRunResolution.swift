public import Foundation

/// The app-side outcome of invoking one live Cmd+Shift+P action.
public enum ControlCommandPaletteRunResolution: Sendable, Equatable {
    /// No live main window matched the routing selectors.
    case windowNotFound
    /// The requested identifier is not available in the window's current
    /// command-palette context.
    case commandNotFound
    /// The same action registered for Cmd+Shift+P was invoked.
    case ran(windowID: UUID, command: ControlCommandPaletteItem)
}

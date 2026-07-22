public import Foundation

/// The app-side outcome of invoking one live Cmd+Shift+P action.
public enum ControlCommandPaletteRunResolution: Sendable, Equatable {
    /// No live main window matched the routing selectors.
    case windowNotFound
    /// The requested identifier is not available in the window's current
    /// command-palette context.
    case commandNotFound
    /// The same action registered for Cmd+Shift+P completed synchronously.
    case completed(windowID: UUID, command: ControlCommandPaletteItem)
    /// The action presented UI that owns the remaining interaction.
    case presented(windowID: UUID, command: ControlCommandPaletteItem)
    /// Required statically declared arguments were omitted.
    case requiresArguments(
        windowID: UUID,
        command: ControlCommandPaletteItem,
        arguments: [ControlCommandPaletteArgument]
    )
    /// Argument names were not declared by the action.
    case invalidArguments(windowID: UUID, command: ControlCommandPaletteItem, names: [String])
    /// Argument values did not match their statically declared types.
    case invalidArgumentValues(windowID: UUID, command: ControlCommandPaletteItem, names: [String])
    /// The action rejected the invocation or failed to start.
    case failed(windowID: UUID, command: ControlCommandPaletteItem, code: String, message: String)
}

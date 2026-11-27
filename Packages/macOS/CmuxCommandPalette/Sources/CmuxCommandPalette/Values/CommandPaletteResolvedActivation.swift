import Foundation

/// The activation resolved from a ``CommandPalettePendingActivation`` once
/// results are available.
public enum CommandPaletteResolvedActivation: Equatable {
    /// Activate the result at `index`.
    case selected(index: Int)
    /// Activate the command `commandID`.
    case command(commandID: String)
}

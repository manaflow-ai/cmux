import Foundation

/// Which list the palette is showing: the `>`-prefixed command list or the
/// workspace/surface switcher.
public enum CommandPaletteListScope: String, Sendable {
    /// The command list (query prefixed with `>`).
    case commands
    /// The workspace/surface switcher list.
    case switcher
}

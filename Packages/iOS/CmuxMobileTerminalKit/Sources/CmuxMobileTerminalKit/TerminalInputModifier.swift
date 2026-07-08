import Foundation

/// One of the four armable accessory modifiers on the terminal input bar.
public enum TerminalInputModifier: CaseIterable, Hashable, Sendable {
    /// The Control modifier.
    case control
    /// The Option / Alt modifier.
    case alternate
    /// The Command modifier.
    case command
    /// The Shift modifier.
    case shift
}

/// The raw Ghostty modifier bitmask carried by a key trigger.
///
/// Wraps the `UInt32` value of `ghostty_input_trigger_s.mods.rawValue` and exposes
/// the four modifiers cmux maps onto a stored shortcut. The bit positions are the
/// Ghostty ABI constants (`GHOSTTY_MODS_*`), fixed in `ghostty/include/ghostty.h`.
public struct GhosttyModifierMask: Sendable, Equatable, Hashable {
    /// `GHOSTTY_MODS_SHIFT` (`1 << 0`).
    public static let shiftBit: UInt32 = 1 << 0
    /// `GHOSTTY_MODS_CTRL` (`1 << 1`).
    public static let controlBit: UInt32 = 1 << 1
    /// `GHOSTTY_MODS_ALT` (`1 << 2`).
    public static let optionBit: UInt32 = 1 << 2
    /// `GHOSTTY_MODS_SUPER` (`1 << 3`).
    public static let commandBit: UInt32 = 1 << 3

    /// The raw Ghostty modifier bitmask.
    public var rawValue: UInt32

    /// Creates a modifier mask from a raw Ghostty bitmask.
    /// - Parameter rawValue: The value of `ghostty_input_trigger_s.mods.rawValue`.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Whether the Command (`super`) modifier is set.
    public var command: Bool { (rawValue & Self.commandBit) != 0 }
    /// Whether the Shift modifier is set.
    public var shift: Bool { (rawValue & Self.shiftBit) != 0 }
    /// Whether the Option (`alt`) modifier is set.
    public var option: Bool { (rawValue & Self.optionBit) != 0 }
    /// Whether the Control modifier is set.
    public var control: Bool { (rawValue & Self.controlBit) != 0 }

    /// Whether none of the four mapped modifiers are set.
    ///
    /// Used to reject bogus empty triggers, matching the original
    /// `!command && !shift && !option && !control` check.
    public var isEmpty: Bool { !command && !shift && !option && !control }
}

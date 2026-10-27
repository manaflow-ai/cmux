/// The modifier keys a ``Shortcut`` needs, as a platform-neutral value: Chromium keeps an
/// accelerator's modifiers as `ui::EventFlags` (ui/events/event_constants.h, held by
/// `ui::Accelerator` in ui/base/accelerators/accelerator.h) and converts a native event at the
/// platform edge (ui/events/cocoa/cocoa_event_utils.mm). The NSEvent conversion is in
/// `KeyModifiers+AppKit.swift`.
///
/// Each bit has the raw value of the same `NSEvent.ModifierFlags` bit, so an order by raw value,
/// a stored raw value (``SwitchingShortcuts/tabByNumberModifiers``) and a conversion stay the same.
public nonisolated struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 17)
    public static let control = KeyModifiers(rawValue: 1 << 18)
    public static let option = KeyModifiers(rawValue: 1 << 19)
    public static let command = KeyModifiers(rawValue: 1 << 20)

    /// The modifiers that take part in matching; caps lock, fn and numeric pad bits never do.
    public static let relevant: KeyModifiers = [.command, .shift, .option, .control]
}

/// Named key codes: the key-equivalent characters of non-printing keys, as `NSMenuItem` writes
/// them (the function-key code points of NSEvent.h, `NSUpArrowFunctionKey` = U+F700 and on).
extension Shortcut {
    public nonisolated static let upArrowKey = "\u{F700}"
    public nonisolated static let downArrowKey = "\u{F701}"
    public nonisolated static let leftArrowKey = "\u{F702}"
    public nonisolated static let rightArrowKey = "\u{F703}"
    public nonisolated static let homeKey = "\u{F729}"
    public nonisolated static let endKey = "\u{F72B}"
    public nonisolated static let pageUpKey = "\u{F72C}"
    public nonisolated static let pageDownKey = "\u{F72D}"
    public nonisolated static let returnKey = "\r"
    public nonisolated static let tabKey = "\t"
    public nonisolated static let escapeKey = "\u{1B}"
    public nonisolated static let deleteKey = "\u{8}"
    public nonisolated static let spaceKey = " "
}

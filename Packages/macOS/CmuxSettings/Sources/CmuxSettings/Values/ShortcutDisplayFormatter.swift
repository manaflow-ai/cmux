import Foundation

/// Formats stored keyboard shortcuts for UI display.
///
/// Use this shared formatter anywhere cmux shows a ``StoredShortcut`` so named
/// key labels, modifier ordering, chords, and numbered-digit ranges stay aligned
/// between the app target and settings packages.
public struct ShortcutDisplayFormatter: Sendable {
    /// Creates a shortcut display formatter.
    public init() {}

    /// The range label shown for numbered workspace/surface shortcut families.
    public var numberedDigitRangeHint: String { "1…9" }

    /// Formats a stored shortcut, optionally treating digits `1...9` as a range placeholder.
    ///
    /// - Parameters:
    ///   - shortcut: The stored shortcut to display.
    ///   - numbered: Whether `1...9` digits should render as ``numberedDigitRangeHint``.
    /// - Returns: A localized display string for the shortcut.
    public func displayString(_ shortcut: StoredShortcut, numbered: Bool = false) -> String {
        if shortcut.isUnbound {
            return String(localized: "shortcut.unbound.displayValue", defaultValue: "None")
        }
        if numbered {
            if let second = shortcut.second {
                if isNumberedDigitKey(second.key) {
                    return displayString(shortcut.first)
                        + " "
                        + modifierDisplayString(second)
                        + numberedDigitRangeHint
                }
            } else if isNumberedDigitKey(shortcut.first.key) {
                return modifierDisplayString(shortcut.first) + numberedDigitRangeHint
            }
        }
        if let second = shortcut.second {
            return "\(displayString(shortcut.first)) \(displayString(second))"
        }
        return displayString(shortcut.first)
    }

    /// Formats a single shortcut stroke.
    ///
    /// - Parameter stroke: The shortcut stroke to display.
    /// - Returns: The modifier glyphs followed by the key label.
    public func displayString(_ stroke: ShortcutStroke) -> String {
        strokeDisplayString(
            key: stroke.key,
            command: stroke.command,
            shift: stroke.shift,
            option: stroke.option,
            control: stroke.control
        )
    }

    /// Formats a single shortcut stroke from primitive values.
    ///
    /// - Parameters:
    ///   - key: The stored shortcut key token.
    ///   - command: Whether the Command modifier is present.
    ///   - shift: Whether the Shift modifier is present.
    ///   - option: Whether the Option modifier is present.
    ///   - control: Whether the Control modifier is present.
    /// - Returns: The modifier glyphs followed by the key label.
    public func strokeDisplayString(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> String {
        modifierDisplayString(command: command, shift: shift, option: option, control: control)
            + keyDisplayString(key)
    }

    /// Formats modifier booleans in cmux's standard `Control`, `Option`, `Shift`, `Command` order.
    ///
    /// - Parameters:
    ///   - command: Whether the Command modifier is present.
    ///   - shift: Whether the Shift modifier is present.
    ///   - option: Whether the Option modifier is present.
    ///   - control: Whether the Control modifier is present.
    /// - Returns: The modifier glyphs for the provided booleans.
    public func modifierDisplayString(
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> String {
        var result = ""
        if control { result.append("⌃") }
        if option { result.append("⌥") }
        if shift { result.append("⇧") }
        if command { result.append("⌘") }
        return result
    }

    /// Formats just the modifier symbols of a shortcut stroke.
    ///
    /// - Parameter stroke: The shortcut stroke whose modifiers should be shown.
    /// - Returns: The modifier glyphs for `stroke`.
    public func modifierDisplayString(_ stroke: ShortcutStroke) -> String {
        modifierDisplayString(
            command: stroke.command,
            shift: stroke.shift,
            option: stroke.option,
            control: stroke.control
        )
    }

    /// Formats a stored shortcut key token.
    ///
    /// - Parameter key: The stored key token, such as `"space"`, `"media.mute"`, or `"a"`.
    /// - Returns: A localized key label when one exists, otherwise the uppercased key token.
    public func keyDisplayString(_ key: String) -> String {
        switch key {
        case "\t", "tab", "Tab":
            return String(localized: "shortcut.key.tab", defaultValue: "Tab")
        case "space":
            return String(localized: "shortcut.key.space", defaultValue: "Space")
        case "\r":
            return "↩"
        case "media.brightnessDown":
            return String(localized: "shortcut.key.mediaBrightnessDown", defaultValue: "Brightness Down")
        case "media.brightnessUp":
            return String(localized: "shortcut.key.mediaBrightnessUp", defaultValue: "Brightness Up")
        case "media.mute":
            return String(localized: "shortcut.key.mediaMute", defaultValue: "Mute")
        case "media.next":
            return String(localized: "shortcut.key.mediaNext", defaultValue: "Next Track")
        case "media.playPause":
            return String(localized: "shortcut.key.mediaPlayPause", defaultValue: "Play/Pause")
        case "media.previous":
            return String(localized: "shortcut.key.mediaPrevious", defaultValue: "Previous Track")
        case "media.volumeDown":
            return String(localized: "shortcut.key.mediaVolumeDown", defaultValue: "Volume Down")
        case "media.volumeUp":
            return String(localized: "shortcut.key.mediaVolumeUp", defaultValue: "Volume Up")
        default:
            if let functionKeyDisplayString = functionKeyDisplayString(for: key) {
                return functionKeyDisplayString
            }
            return key.uppercased()
        }
    }

    /// Whether a key token is a valid numbered shortcut placeholder digit.
    ///
    /// - Parameter key: The stored key token to check.
    /// - Returns: `true` when `key` is one of the digits `1...9`.
    public func isNumberedDigitKey(_ key: String) -> Bool {
        guard let digit = Int(key) else { return false }
        return (1...9).contains(digit)
    }

    private func functionKeyDisplayString(for key: String) -> String? {
        guard key.hasPrefix("f"),
              let number = Int(key.dropFirst()),
              (1...20).contains(number) else {
            return nil
        }
        return "F\(number)"
    }
}

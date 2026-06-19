#if DEBUG
public import AppKit

extension NSEvent.ModifierFlags {
    /// Device-independent command/shift/option/control subset of these flags,
    /// dropping numeric-pad, function, and caps-lock bits.
    public var commandPaletteNormalized: NSEvent.ModifierFlags {
        intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    /// DEBUG-only `+`-joined token list of the active normalized modifier flags
    /// (`"none"` when empty), for the command-palette debug log.
    public var commandPaletteModifierDebugSummary: String {
        let normalized = commandPaletteNormalized
        var parts: [String] = []
        if normalized.contains(.command) { parts.append("cmd") }
        if normalized.contains(.shift) { parts.append("shift") }
        if normalized.contains(.option) { parts.append("opt") }
        if normalized.contains(.control) { parts.append("ctrl") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}

extension NSEvent {
    /// DEBUG-only one-line summary of this event's type, key code, modifier
    /// flags, and characters for the command-palette debug log.
    public var commandPaletteEventDebugSummary: String {
        let chars = characters.map(String.init(reflecting:)) ?? "nil"
        let charsIgnoring = charactersIgnoringModifiers.map(String.init(reflecting:)) ?? "nil"
        return
            "type=\(type) keyCode=\(keyCode) flags=\(modifierFlags.commandPaletteModifierDebugSummary) " +
            "chars=\(chars) charsIgnoring=\(charsIgnoring)"
    }
}
#endif

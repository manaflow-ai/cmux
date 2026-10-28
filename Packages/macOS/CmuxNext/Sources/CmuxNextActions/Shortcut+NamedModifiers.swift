import AppKit

/// A shortcut's modifiers by name, for the layers that build and read shortcuts without
/// importing AppKit (CmuxNextSettings: cmux-next.json's `cmd+shift+p`). p15-oracle-127's
/// `KeyModifiers` value type later replaces the `NSEvent.ModifierFlags` behind these.
extension Shortcut {
    /// `key` with the named modifiers; `Shortcut(key: "p", command: true, shift: true)` is Cmd-Shift-P.
    public nonisolated init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        var modifiers: NSEvent.ModifierFlags = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        self.init(key, modifiers: modifiers)
    }

    public nonisolated var hasCommand: Bool { modifiers.contains(.command) }
    public nonisolated var hasShift: Bool { modifiers.contains(.shift) }
    public nonisolated var hasOption: Bool { modifiers.contains(.option) }
    public nonisolated var hasControl: Bool { modifiers.contains(.control) }
}

public import AppKit
public import CmuxTerminalCopyMode

extension TerminalKeyboardCopyModeModifiers {
    /// Maps AppKit modifier flags into the platform-neutral copy-mode set.
    ///
    /// Only the device-independent bits participate; side-specific device bits
    /// never affect copy-mode command matching.
    ///
    /// - Parameter modifierFlags: The flags from the keyboard event.
    public init(modifierFlags: NSEvent.ModifierFlags) {
        let normalized = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: TerminalKeyboardCopyModeModifiers = []
        if normalized.contains(.command) {
            modifiers.insert(.command)
        }
        if normalized.contains(.shift) {
            modifiers.insert(.shift)
        }
        if normalized.contains(.control) {
            modifiers.insert(.control)
        }
        if normalized.contains(.numericPad) {
            modifiers.insert(.numericPad)
        }
        if normalized.contains(.function) {
            modifiers.insert(.function)
        }
        if normalized.contains(.capsLock) {
            modifiers.insert(.capsLock)
        }
        self = modifiers
    }
}

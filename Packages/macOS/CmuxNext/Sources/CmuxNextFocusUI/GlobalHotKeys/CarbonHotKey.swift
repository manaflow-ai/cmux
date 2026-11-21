package import Carbon.HIToolbox
package import CmuxNextActions

/// One native registration per action and physical key. Several configured
/// spellings of the same physical key share the registration.
package struct GlobalHotKeyBinding: Hashable {
    package var id: ActionID
    package var hotKey: CarbonHotKey

    package init(id: ActionID, hotKey: CarbonHotKey) {
        self.id = id
        self.hotKey = hotKey
    }
}

/// A system-wide hot key as Carbon takes it: a virtual key code and a
/// Carbon modifier mask.
package struct CarbonHotKey: Hashable, Sendable {
    package var keyCode: UInt32
    package var modifiers: UInt32

    package init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The hot key for `shortcut`, or nil when no key on `layout` types its
    /// character.
    package init?(_ shortcut: Shortcut, layout: KeyCodeLayout) {
        guard let keyCode = layout.keyCode(for: shortcut.key) else { return nil }
        var modifiers: UInt32 = 0
        if shortcut.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if shortcut.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }
}

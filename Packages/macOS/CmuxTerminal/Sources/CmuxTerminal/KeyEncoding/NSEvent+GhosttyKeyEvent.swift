public import AppKit
public import GhosttyKit

extension NSEvent {
    /// The unshifted codepoint for this key event, used to populate
    /// ``ghostty_input_key_s/unshifted_codepoint``.
    ///
    /// `layoutCharacter` is the layout-derived character for this event's
    /// physical key (`KeyboardLayout.character(forKeyCode:)`), supplied by the
    /// app so the package stays free of the app-side `KeyboardLayout`. When that
    /// layout character is a single printable, non-PUA scalar it wins; otherwise
    /// the event's own (modifier-stripped) characters are used.
    @inlinable
    public func ghosttyUnshiftedCodepoint(layoutCharacter: String?) -> UInt32 {
        if let layoutChars = layoutCharacter,
           layoutChars.count == 1,
           let layoutScalar = layoutChars.unicodeScalars.first,
           layoutScalar.value >= 0x20,
           !(layoutScalar.value >= 0xF700 && layoutScalar.value <= 0xF8FF) {
            return layoutScalar.value
        }

        guard let chars = (characters(byApplyingModifiers: []) ?? charactersIgnoringModifiers ?? characters),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    /// Builds the libghostty press key event (`ghostty_input_key_s`) for this
    /// `NSEvent` against `surface`.
    ///
    /// Mods preserve sided input (``terminalGhosttyKeyMods``); consumed mods are
    /// derived from libghostty's translation mods for this surface
    /// (`ghostty_surface_key_translation_mods`, which respects config such as
    /// `macos-option-as-alt`). `text`/`composing` are left empty here; callers
    /// fill text from the AppKit IME path. `layoutCharacter` is forwarded to
    /// ``ghosttyUnshiftedCodepoint(layoutCharacter:)``.
    @inlinable
    public func ghosttyKeyEvent(
        surface: ghostty_surface_t,
        layoutCharacter: String?
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.mods = terminalGhosttyKeyMods

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, terminalGhosttyKeyMods)
        let translationMods = modifierFlags.terminalGhosttyTranslationFlags(
            ghosttyTranslationMods: translationModsGhostty
        )

        keyEvent.consumed_mods = translationMods.terminalGhosttyConsumedMods
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = ghosttyUnshiftedCodepoint(layoutCharacter: layoutCharacter)
        return keyEvent
    }
}

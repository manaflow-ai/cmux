public import AppKit
public import GhosttyKit

extension NSEvent.ModifierFlags {
    /// Translates these modifier flags into the libghostty mods bitfield for
    /// key events (`ghostty_surface_key`, `ghostty_surface_key_translation_mods`).
    ///
    /// Sided input is preserved (mirrors Ghostty.app's `ghosttyMods`): libghostty
    /// applies `macos-option-as-alt = left|right` and the key encoder's per-side
    /// Alt-prefix rules from these bits; without them every modifier reads as the
    /// left key (https://github.com/manaflow-ai/cmux/issues/5993).
    @inlinable
    public var terminalGhosttyKeyMods: ghostty_input_mods_e {
        let rawValue = self.rawValue
        var mods = GHOSTTY_MODS_NONE.rawValue
        if contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }

        if rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawValue & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Translates these modifier flags into libghostty mods for mouse, hover,
    /// and link updates. libghostty keeps only binding modifiers for mouse state
    /// (`Mods.binding()` — "we don't want caps/num lock or sided modifiers to
    /// affect the mouse") but compares incoming mods against that stored value,
    /// so sending side bits would make every event with a held right-side
    /// modifier look like a modifier change and re-dirty the screen. Key events
    /// must keep the side bits (``terminalGhosttyKeyMods``); mouse paths send the
    /// normalized binding bits libghostty stores.
    @inlinable
    public var terminalGhosttyMouseMods: ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// are excluded from consumed_mods.
    @inlinable
    public var terminalGhosttyConsumedMods: ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Applies libghostty's translation mods (the modifiers that should
    /// participate in character translation after settings such as
    /// `macos-option-as-alt` are applied) back onto these modifier flags,
    /// preserving flags libghostty does not model (function, numeric pad, ...).
    @inlinable
    public func terminalGhosttyTranslationFlags(
        ghosttyTranslationMods: ghostty_input_mods_e
    ) -> NSEvent.ModifierFlags {
        var translationMods = self
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (ghosttyTranslationMods.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (ghosttyTranslationMods.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (ghosttyTranslationMods.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (ghosttyTranslationMods.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }
        return translationMods
    }
}

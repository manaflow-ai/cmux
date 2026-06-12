import AppKit
import GhosttyKit

/// Translates NSEvent modifier flags into the libghostty mods bitfield used by
/// `ghostty_surface_key`, `ghostty_surface_key_translation_mods`, and the
/// mouse APIs.
nonisolated func cmuxGhosttyModsFromFlags(modifierFlagsRawValue rawValue: UInt) -> ghostty_input_mods_e {
    let flags = NSEvent.ModifierFlags(rawValue: rawValue)
    var mods = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }

    // Sided input (mirrors Ghostty.app's ghosttyMods). libghostty applies
    // `macos-option-as-alt = left|right` and the key encoder's per-side
    // Alt-prefix rules from these bits; without them every modifier reads
    // as the left key (https://github.com/manaflow-ai/cmux/issues/5993).
    if rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if rawValue & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

    return ghostty_input_mods_e(rawValue: mods)
}

/// Applies libghostty's translation mods (the modifiers that should
/// participate in character translation after settings such as
/// `macos-option-as-alt` are applied) back onto an event's modifier flags,
/// preserving flags libghostty does not model (function, numeric pad, ...).
nonisolated func cmuxTranslationModifierFlags(
    original eventFlags: NSEvent.ModifierFlags,
    ghosttyTranslationMods: ghostty_input_mods_e
) -> NSEvent.ModifierFlags {
    var translationMods = eventFlags
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

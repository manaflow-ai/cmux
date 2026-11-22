import AppKit
import Carbon.HIToolbox
import GhosttyNextKit

/// NSEvent -> `ghostty_input_key_s` translation (ghostty.h:300-308).
nonisolated enum GhosttyInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        // Right-side modifiers, from the device-dependent bits.
        let device = flags.rawValue
        if device & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if device & UInt(NX_DEVICERCTLKEYMASK) != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if device & UInt(NX_DEVICERALTKEYMASK) != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if device & UInt(NX_DEVICERCMDKEYMASK) != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// `ghostty_input_key_s` without `text`, whose C string lifetime the
    /// caller controls.
    static func keyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.composing = false
        key.mods = mods(event.modifierFlags)
        // Control and Command never produce text on macOS; everything else
        // is assumed to have been consumed by translation.
        key.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        return key
    }

    static func translationEvent(for event: NSEvent, translationMods: ghostty_input_mods_e) -> NSEvent {
        let wanted = flags(translationMods)
        var modifierFlags = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if wanted.contains(flag) { modifierFlags.insert(flag) } else { modifierFlags.remove(flag) }
        }
        guard modifierFlags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: modifierFlags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    /// Text for a plain key event: control characters are replaced by the
    /// unmodified character (Ghostty encodes Ctrl itself) and function-key
    /// private-use characters are dropped.
    static func keyText(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if (0xF700...0xF8FF).contains(scalar.value) {
                return nil
            }
        }
        return characters
    }

    static func startsWithControlCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// A lone C0 control produced while composing belongs to the IME.
    static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else {
            return false
        }
        return scalar.value < 0x20
    }

    /// Arrow keys still move the cursor after an IME commits on them.
    /// Plain Left is excluded because Korean IMEs already leave the caret.
    static func shouldReplayAfterCommit(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_DownArrow, kVK_RightArrow, kVK_UpArrow:
            return true
        case kVK_LeftArrow:
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }

    /// Press or release for a modifier key, honoring left/right sides.
    static func modifierAction(for event: NSEvent) -> ghostty_input_action_e? {
        let mod: UInt32
        let rightMask: UInt32?
        switch Int(event.keyCode) {
        case kVK_CapsLock: mod = GHOSTTY_MODS_CAPS.rawValue; rightMask = nil
        case kVK_Shift: mod = GHOSTTY_MODS_SHIFT.rawValue; rightMask = nil
        case kVK_RightShift: mod = GHOSTTY_MODS_SHIFT.rawValue; rightMask = UInt32(NX_DEVICERSHIFTKEYMASK)
        case kVK_Control: mod = GHOSTTY_MODS_CTRL.rawValue; rightMask = nil
        case kVK_RightControl: mod = GHOSTTY_MODS_CTRL.rawValue; rightMask = UInt32(NX_DEVICERCTLKEYMASK)
        case kVK_Option: mod = GHOSTTY_MODS_ALT.rawValue; rightMask = nil
        case kVK_RightOption: mod = GHOSTTY_MODS_ALT.rawValue; rightMask = UInt32(NX_DEVICERALTKEYMASK)
        case kVK_Command: mod = GHOSTTY_MODS_SUPER.rawValue; rightMask = nil
        case kVK_RightCommand: mod = GHOSTTY_MODS_SUPER.rawValue; rightMask = UInt32(NX_DEVICERCMDKEYMASK)
        default: return nil
        }
        guard mods(event.modifierFlags).rawValue & mod != 0 else { return GHOSTTY_ACTION_RELEASE }
        // The modifier is held; it is a press only if this side is down.
        if let rightMask, UInt32(truncatingIfNeeded: event.modifierFlags.rawValue) & rightMask == 0 {
            return GHOSTTY_ACTION_RELEASE
        }
        return GHOSTTY_ACTION_PRESS
    }

    static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    /// The lowercase character a physical key types with no modifiers, for
    /// matching Latin command keys under a Korean or Russian layout. Uses the
    /// current layout when it yields ASCII, else the ASCII-capable source
    /// (Korean 두벌식 has layout data but still translates to Hangul).
    static func asciiCharacter(forKeyCode keyCode: UInt16) -> String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let result = character(in: source, keyCode: keyCode), result.allSatisfy(\.isASCII) {
            return result
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return character(in: source, keyCode: keyCode)
    }

    private static func character(in source: TISInputSource, keyCode: UInt16) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased()
    }
}

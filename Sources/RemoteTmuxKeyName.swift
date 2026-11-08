import Carbon.HIToolbox
import CmuxRemoteSession
import GhosttyKit

extension RemoteTmuxKeyName {
    /// Resolves navigation and function keys whose local xterm encoding can
    /// disagree with the remote pane's tmux terminfo and terminal modes.
    init?(inputEvent: ghostty_input_key_s) {
        guard inputEvent.action == GHOSTTY_ACTION_PRESS
                || inputEvent.action == GHOSTTY_ACTION_REPEAT,
              !inputEvent.composing else {
            return nil
        }

        let base: String
        switch Int(inputEvent.keycode) {
        case kVK_Home: base = "Home"
        case kVK_End: base = "End"
        case kVK_Help: base = "IC"
        case kVK_ForwardDelete: base = "DC"
        case kVK_PageUp: base = "PPage"
        case kVK_PageDown: base = "NPage"
        case kVK_UpArrow: base = "Up"
        case kVK_DownArrow: base = "Down"
        case kVK_LeftArrow: base = "Left"
        case kVK_RightArrow: base = "Right"
        case kVK_F1: base = "F1"
        case kVK_F2: base = "F2"
        case kVK_F3: base = "F3"
        case kVK_F4: base = "F4"
        case kVK_F5: base = "F5"
        case kVK_F6: base = "F6"
        case kVK_F7: base = "F7"
        case kVK_F8: base = "F8"
        case kVK_F9: base = "F9"
        case kVK_F10: base = "F10"
        case kVK_F11: base = "F11"
        case kVK_F12: base = "F12"
        default: return nil
        }

        // AppKit sometimes supplies the private-use function-key character
        // even though this is still a physical, non-text key. Reject real text
        // so an IME commit can never be replaced by a tmux key command.
        if let textPointer = inputEvent.text {
            let text = String(cString: textPointer)
            if !text.isEmpty {
                guard text.unicodeScalars.count == 1,
                      let scalar = text.unicodeScalars.first,
                      (0xF700...0xF8FF).contains(scalar.value) else {
                    return nil
                }
            }
        }

        let rawModifiers = inputEvent.mods.rawValue
        guard rawModifiers & GHOSTTY_MODS_SUPER.rawValue == 0 else { return nil }
        var modifiers: [String] = []
        modifiers.reserveCapacity(3)
        if rawModifiers & GHOSTTY_MODS_CTRL.rawValue != 0 { modifiers.append("C") }
        if rawModifiers & GHOSTTY_MODS_ALT.rawValue != 0 { modifiers.append("M") }
        if rawModifiers & GHOSTTY_MODS_SHIFT.rawValue != 0 { modifiers.append("S") }
        self.init(rawName: (modifiers + [base]).joined(separator: "-"))
    }
}

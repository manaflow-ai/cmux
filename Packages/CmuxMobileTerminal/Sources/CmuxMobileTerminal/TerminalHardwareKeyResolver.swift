#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileTerminalKit
import Foundation
import UIKit

struct TerminalHardwareKeyResolver {
    private init() {}

    private static let supportedModifierFlags: UIKeyModifierFlags = [.shift, .control, .alternate]
    private static let keyCommands: [TerminalHardwareKeyCommand] = {
        let navigation = [
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputHome, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputEnd, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: []),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: []),
            // NOTE: plain Delete is intentionally NOT a key command. A
            // `UIKeyCommand` for `inputDelete` intercepts BOTH the hardware and the
            // software keyboard's Delete and fires only once per press — UIKeyCommands
            // do not auto-repeat — which broke hold-to-repeat Backspace. Plain Delete
            // is handled by `TerminalInputTextView.deleteBackward()` instead (forwards
            // DEL to the Mac and auto-repeats while held, given `hasText == true`).
            // Option+Delete (delete-word) stays a key command: it is a distinct
            // hardware shortcut that `deleteBackward` cannot express.
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [.alternate]),
            TerminalHardwareKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: []),
            TerminalHardwareKeyCommand(input: "\t", modifierFlags: []),
            TerminalHardwareKeyCommand(input: "\t", modifierFlags: [.shift]),
        ]
        let controlInputs = Array("abcdefghijklmnopqrstuvwxyz[]\\ 234567/").map(String.init)
            .map { TerminalHardwareKeyCommand(input: $0, modifierFlags: [.control]) }
        let shiftedControlInputs = Array("@^_?").map(String.init)
            .map { TerminalHardwareKeyCommand(input: $0, modifierFlags: [.control, .shift]) }
        return navigation + controlInputs + shiftedControlInputs
    }()

    static func makeKeyCommands(target: Any, action: Selector) -> [UIKeyCommand] {
        keyCommands.map { command in
            UIKeyCommand(
                input: command.input,
                modifierFlags: command.modifierFlags,
                action: action
            )
        }
    }

    /// Maps a `UIKeyCommand.input*` string to a platform-neutral special key.
    /// Returns `nil` for ordinary character inputs.
    private static func specialKey(for input: String) -> TerminalSpecialKey? {
        switch input {
        case UIKeyCommand.inputUpArrow: return .upArrow
        case UIKeyCommand.inputDownArrow: return .downArrow
        case UIKeyCommand.inputLeftArrow: return .leftArrow
        case UIKeyCommand.inputRightArrow: return .rightArrow
        case UIKeyCommand.inputHome: return .home
        case UIKeyCommand.inputEnd: return .end
        case UIKeyCommand.inputPageUp: return .pageUp
        case UIKeyCommand.inputPageDown: return .pageDown
        case UIKeyCommand.inputDelete: return .delete
        case UIKeyCommand.inputEscape: return .escape
        case "\t": return .tab
        default: return nil
        }
    }

    /// Translates `UIKeyModifierFlags` into the kit's platform-neutral set.
    private static func kitModifiers(_ flags: UIKeyModifierFlags) -> TerminalKeyModifier {
        var result: TerminalKeyModifier = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.alternate) }
        return result
    }

    static func data(input: String, modifierFlags: UIKeyModifierFlags) -> Data? {
        let modifiers = kitModifiers(modifierFlags)
        if let key = specialKey(for: input) {
            return TerminalKeyEncoder.encode(specialKey: key, modifiers: modifiers)
        }
        return TerminalKeyEncoder.encode(character: input, modifiers: modifiers)
    }
}
#endif

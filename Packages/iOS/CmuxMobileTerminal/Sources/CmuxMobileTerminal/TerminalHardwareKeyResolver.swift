#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileTerminalKit
import Foundation
import UIKit

/// Stateless namespace that encodes a UIKit key chord (a `UIKeyCommand.input*`
/// string or typed character plus `UIKeyModifierFlags`) into the terminal's VT
/// byte sequence, bridging UIKit input types to ``TerminalKeyEncoder``.
struct TerminalHardwareKeyResolver {
    private init() {}

    // No `UIKeyCommand` table lives here anymore. Hardware keys are captured
    // exclusively by `TerminalInputTextView.pressesBegan` (which runs below the
    // text-editing layer); a parallel `keyCommands` set produced a second,
    // racing handler for the same arrows/Ctrl/Shift-Arrow chords — the source of
    // the inconsistent ("janky") modifier behavior. `pressesBegan` now routes
    // every special key and Control/Option/Shift chord straight through `data`
    // below. The lone surviving `UIKeyCommand` (Cmd+V → paste) is wired in
    // `TerminalInputTextView.keyCommands`, since `shouldConsume` deliberately
    // lets plain Command fall through to the system paste path.

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

    /// Encode `input` + `modifierFlags` to terminal bytes: a special-key input
    /// routes through the special-key encoder, any other input through the
    /// character encoder. Returns `nil` when the combination has no encoding.
    static func data(input: String, modifierFlags: UIKeyModifierFlags) -> Data? {
        let modifiers = kitModifiers(modifierFlags)
        if let key = specialKey(for: input) {
            return TerminalKeyEncoder.encode(specialKey: key, modifiers: modifiers)
        }
        return TerminalKeyEncoder.encode(character: input, modifiers: modifiers)
    }
}
#endif

import AppKit
import Foundation

extension GlobalSearchKeyEvent {
    /// Whether the search query's field editor owns this event as native text input.
    var queryOwnsEditingShortcut: Bool {
        let flags = modifierFlags
        let commandControlOption = flags.intersection([.command, .control, .option])

        if commandControlOption == [.command] {
            return isCommandEditingCharacter || isTextNavigationOrDeletionKey
        }
        if commandControlOption == [.control] {
            return isControlEditingCharacter || isTextNavigationOrDeletionKey
        }
        if commandControlOption == [.option] {
            return isPrintableTextInput || isTextNavigationOrDeletionKey
        }
        if commandControlOption.isEmpty, flags.contains(.shift) {
            return isPrintableTextInput || isTextNavigationOrDeletionKey
        }
        return false
    }

    private var isCommandEditingCharacter: Bool {
        guard let character = charactersIgnoringModifiers?.lowercased() else { return false }
        return ["a", "c", "v", "x", "z"].contains(character)
    }

    private var isControlEditingCharacter: Bool {
        guard let character = charactersIgnoringModifiers?.lowercased() else { return false }
        return ["a", "b", "d", "e", "f", "h", "k", "l", "n", "o", "p", "t", "v", "y"]
            .contains(character)
    }

    private var isTextNavigationOrDeletionKey: Bool {
        switch keyCode {
        case 51, 115, 116, 117, 119, 121, 123, 124, 125, 126:
            return true
        default:
            return false
        }
    }

    private var isPrintableTextInput: Bool {
        guard let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && (scalar.value < 0xF700 || scalar.value > 0xF8FF)
        }
    }
}

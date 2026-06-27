#if canImport(UIKit)
import UIKit

struct TerminalHardwareKeyCommand: Sendable {
    let input: String
    let modifierFlags: UIKeyModifierFlags

    nonisolated init(input: String, modifierFlags: UIKeyModifierFlags) {
        self.input = input
        self.modifierFlags = modifierFlags
    }
}
#endif

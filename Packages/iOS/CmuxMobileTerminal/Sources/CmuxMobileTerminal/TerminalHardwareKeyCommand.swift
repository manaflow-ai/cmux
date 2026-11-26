#if canImport(UIKit)
import UIKit

struct TerminalHardwareKeyCommand: Sendable {
    let input: String
    let modifierFlags: UIKeyModifierFlags
}
#endif

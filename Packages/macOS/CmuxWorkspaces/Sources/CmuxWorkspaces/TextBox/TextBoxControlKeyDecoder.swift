import Carbon.HIToolbox

/// Pure Control-key / mention-navigation decoding lifted out of the app-target
/// `TextBoxInputTextView` (`Sources/TextBoxInput.swift`).
///
/// The live `NSTextView` stays app-side and extracts the primitives from the
/// incoming `NSEvent` (`event.keyCode`, `event.charactersIgnoringModifiers`, and
/// the `KeyboardLayout`-resolved normalized characters, all of which stay
/// app-side), then forwards them here. This type carries no AppKit/event state:
/// it decides which logical key a Control-modified keystroke maps to and which
/// of those keys the text box handles locally versus forwards to the terminal.
///
/// `localControlKeys` is instance state so callers configure the locally-handled
/// set at construction; the default initializer reproduces the exact set the god
/// file hardcoded (the readline editing keys the text box keeps for itself).
public struct TextBoxControlKeyDecoder: Sendable, Equatable {
    /// The Control-modified keys the text box handles itself (readline-style
    /// editing) rather than forwarding to the terminal.
    public let localControlKeys: Set<String>

    /// Creates a decoder. The default reproduces the locally-handled set the text
    /// box has always used; tests may override it.
    public init(localControlKeys: Set<String> = ["a", "e", "f", "b", "n", "p", "k", "h"]) {
        self.localControlKeys = localControlKeys
    }

    /// Whether `key` is handled locally by the text box (so the keystroke goes to
    /// `super.keyDown`) rather than forwarded to the terminal.
    public func isLocalControlKey(_ key: String) -> Bool {
        localControlKeys.contains(key)
    }

    /// The logical Control key for a keystroke: the physical (layout-independent)
    /// mapping when the key code is a known ANSI letter/backslash, otherwise the
    /// lowercased characters-ignoring-modifiers the event already carried.
    public func controlKey(keyCode: Int, charactersIgnoringModifiers: String?) -> String? {
        Self.physicalControlKey(forKeyCode: keyCode) ?? charactersIgnoringModifiers?.lowercased()
    }

    /// The key used for Control-driven navigation of the mention-completion list.
    /// A single-ASCII normalized character (from the active keyboard layout) wins
    /// so layout remapping is honored; otherwise it falls back to `controlKey`.
    public func mentionCompletionControlNavigationKey(
        keyCode: Int,
        charactersIgnoringModifiers: String?,
        normalizedCharacters: String
    ) -> String? {
        let normalizedKey = normalizedCharacters.lowercased()
        if normalizedKey.count == 1, normalizedKey.allSatisfy(\.isASCII) {
            return normalizedKey
        }
        return controlKey(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers)
    }

    /// The layout-independent letter (or backslash) for a physical `keyCode`,
    /// using the Carbon `kVK_ANSI_*` virtual key codes. Returns `nil` for key
    /// codes outside that set so callers fall back to the event characters.
    public static func physicalControlKey(forKeyCode keyCode: Int) -> String? {
        switch keyCode {
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"
        case kVK_ANSI_Backslash: return "\\"
        default:
            return nil
        }
    }
}

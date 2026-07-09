public import AppKit

/// The browser page-zoom command a Command-modified keystroke maps to, or the
/// absence of one when the keystroke is not a zoom shortcut.
///
/// The cmux app target used to inline the zoom decision as free functions in its
/// shortcut routing support file (`browserZoomShortcutAction`,
/// `browserZoomShortcutKeyCandidates`, and the `#if DEBUG` trace helpers). The
/// decision is a pure mapping from a modifier-flag set plus the pressed key to
/// one of three zoom commands, with no AppKit responder, `Workspace`, or
/// `BrowserPanel` reach, so it belongs in this package next to the omnibar
/// routing decisions that share the file.
///
/// The one app-only coupling is layout translation: the candidate-key set
/// consults the app target's `KeyboardLayout` to recover the produced character
/// for the pressed key code (so a shifted `=` typed from a non-ANSI physical key
/// still matches `+`). That translation cannot move here (`KeyboardLayout` is an
/// app-target type), so it is injected as a `layoutCharacter` closure; the app
/// delegate's forwarders supply `KeyboardLayout.character(forKeyCode:)` as the
/// default. The factory is a static member on the produced type rather than a
/// free function or a caseless namespace, so call sites read
/// `BrowserZoomShortcutAction.resolve(...)`. Bodies are byte-faithful lifts.
public enum BrowserZoomShortcutAction: Equatable, Sendable {
    case zoomIn
    case zoomOut
    case reset
}

extension BrowserZoomShortcutAction {
    /// Resolves the zoom command for a keystroke, or `nil` when the keystroke is
    /// not a Command-only (optionally Shift-modified) zoom shortcut.
    ///
    /// Command is required and Control/Option must be absent. The pressed key is
    /// matched against `=`/`+`/`-`/`_`/`0` (and their ANSI/keypad key codes),
    /// where the candidate-key set folds in the lowercased characters, an
    /// optional pre-shift literal, and the layout-translated character.
    /// - Parameters:
    ///   - flags: The event modifier flags.
    ///   - chars: The pressed characters (post-modifier).
    ///   - keyCode: The event key code.
    ///   - literalChars: The pre-shift literal characters, when known.
    ///   - layoutCharacter: Translates a key code to its produced character via
    ///     the current keyboard layout (the app supplies `KeyboardLayout`).
    /// - Returns: The matched zoom command, or `nil`.
    public static func resolve(
        flags: NSEvent.ModifierFlags,
        chars: String,
        keyCode: UInt16,
        literalChars: String? = nil,
        layoutCharacter: (UInt16) -> String?
    ) -> BrowserZoomShortcutAction? {
        let normalizedFlags = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        let hasCommand = normalizedFlags.contains(.command)
        let hasOnlyCommandAndOptionalShift = hasCommand && normalizedFlags.isDisjoint(with: [.control, .option])

        guard hasOnlyCommandAndOptionalShift else { return nil }
        let keys = keyCandidates(
            chars: chars,
            literalChars: literalChars,
            keyCode: keyCode,
            layoutCharacter: layoutCharacter
        )

        if keys.contains("=") || keys.contains("+") || keyCode == 24 || keyCode == 69 { // kVK_ANSI_Equal / kVK_ANSI_KeypadPlus
            return .zoomIn
        }

        if keys.contains("-") || keys.contains("_") || keyCode == 27 || keyCode == 78 { // kVK_ANSI_Minus / kVK_ANSI_KeypadMinus
            return .zoomOut
        }

        if keys.contains("0") || keyCode == 29 || keyCode == 82 { // kVK_ANSI_0 / kVK_ANSI_Keypad0
            return .reset
        }

        return nil
    }

    /// The set of candidate characters a zoom keystroke could represent: the
    /// lowercased pressed characters, an optional lowercased pre-shift literal,
    /// and the layout-translated character for the key code.
    static func keyCandidates(
        chars: String,
        literalChars: String?,
        keyCode: UInt16,
        layoutCharacter: (UInt16) -> String?
    ) -> Set<String> {
        var keys: Set<String> = [chars.lowercased()]

        if let literalChars, !literalChars.isEmpty {
            keys.insert(literalChars.lowercased())
        }

        if let layoutChar = layoutCharacter(keyCode), !layoutChar.isEmpty {
            keys.insert(layoutChar)
        }

        return keys
    }
}

#if DEBUG
extension BrowserZoomShortcutAction {
    /// Whether a keystroke looks like a Command-modified zoom shortcut, used to
    /// gate verbose zoom-routing trace logging in debug builds.
    public static func traceCandidate(
        flags: NSEvent.ModifierFlags,
        chars: String,
        keyCode: UInt16,
        literalChars: String? = nil,
        layoutCharacter: (UInt16) -> String?
    ) -> Bool {
        let normalizedFlags = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        guard normalizedFlags.contains(.command) else { return false }

        let keys = keyCandidates(
            chars: chars,
            literalChars: literalChars,
            keyCode: keyCode,
            layoutCharacter: layoutCharacter
        )
        if keys.contains("=") || keys.contains("+") || keys.contains("-") || keys.contains("_") || keys.contains("0") {
            return true
        }
        switch keyCode {
        case 24, 27, 29, 69, 78, 82: // ANSI and keypad zoom keys
            return true
        default:
            return false
        }
    }

    /// A compact `Cmd+Shift+Opt+Ctrl`-style description of the zoom-relevant
    /// modifier flags for debug trace logging.
    public static func traceFlagsString(_ flags: NSEvent.ModifierFlags) -> String {
        let normalizedFlags = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        var parts: [String] = []
        if normalizedFlags.contains(.command) { parts.append("Cmd") }
        if normalizedFlags.contains(.shift) { parts.append("Shift") }
        if normalizedFlags.contains(.option) { parts.append("Opt") }
        if normalizedFlags.contains(.control) { parts.append("Ctrl") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    /// A short label for a resolved zoom action (or `"none"`) for debug trace
    /// logging.
    public static func traceActionString(_ action: BrowserZoomShortcutAction?) -> String {
        guard let action else { return "none" }
        switch action {
        case .zoomIn: return "zoomIn"
        case .zoomOut: return "zoomOut"
        case .reset: return "reset"
        }
    }
}
#endif

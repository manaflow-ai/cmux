private func terminalKeyboardCopyModeNormalizedModifiers(
    _ modifiers: TerminalKeyboardCopyModeModifiers
) -> TerminalKeyboardCopyModeModifiers {
    modifiers.subtracting([.numericPad, .function, .capsLock])
}

private func terminalKeyboardCopyModeChars(
    _ charactersIgnoringModifiers: String?,
    keyCode: UInt16,
    asciiCharacterProvider: (UInt16) -> String?
) -> String {
    let raw = charactersIgnoringModifiers?.unicodeScalars.first.map { String($0).lowercased() } ?? ""
    if raw.allSatisfy(\.isASCII) { return raw }

    if let asciiScalar = asciiCharacterProvider(keyCode)?.unicodeScalars.first {
        return String(asciiScalar).lowercased()
    }
    return raw
}

/// Returns whether copy mode should bypass an event so app-level shortcuts can handle it.
///
/// Copy mode owns ordinary navigation keys but must not swallow app-level
/// shortcuts such as Command-C or Command-Shift-M. Use this before invoking
/// ``terminalKeyboardCopyModeResolve(keyCode:charactersIgnoringModifiers:modifiers:hasSelection:state:asciiCharacterProvider:)``.
///
/// ```swift
/// let shouldBypass = terminalKeyboardCopyModeShouldBypassForShortcut(
///     modifiers: [.command, .shift]
/// )
/// ```
///
/// - Parameter modifiers: The event modifiers converted to ``TerminalKeyboardCopyModeModifiers``.
/// - Returns: `true` when the event should stay available to app-level shortcut handling.
public func terminalKeyboardCopyModeShouldBypassForShortcut(
    modifiers: TerminalKeyboardCopyModeModifiers
) -> Bool {
    let normalized = terminalKeyboardCopyModeNormalizedModifiers(modifiers)
    return normalized.contains(.command)
}

/// Resolves a single key event to a terminal copy-mode action.
///
/// This stateless resolver handles one key at a time. For count prefixes and
/// two-key commands such as `gg` and `yy`, use
/// ``terminalKeyboardCopyModeResolve(keyCode:charactersIgnoringModifiers:modifiers:hasSelection:state:asciiCharacterProvider:)``.
///
/// ```swift
/// let action = terminalKeyboardCopyModeAction(
///     keyCode: 38,
///     charactersIgnoringModifiers: "j",
///     modifiers: [],
///     hasSelection: false
/// )
/// ```
///
/// - Parameters:
///   - keyCode: The hardware key code for the event.
///   - charactersIgnoringModifiers: The layout character reported without modifiers.
///   - modifiers: The event modifiers converted to ``TerminalKeyboardCopyModeModifiers``.
///   - hasSelection: Whether visual selection is currently active.
///   - asciiCharacterProvider: A fallback physical-key lookup for non-ASCII input sources.
/// - Returns: A copy-mode action, or `nil` when the key is not a command.
public func terminalKeyboardCopyModeAction(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifiers: TerminalKeyboardCopyModeModifiers,
    hasSelection: Bool,
    asciiCharacterProvider: (UInt16) -> String? = { _ in nil }
) -> TerminalKeyboardCopyModeAction? {
    let normalized = terminalKeyboardCopyModeNormalizedModifiers(modifiers)
    let chars = terminalKeyboardCopyModeChars(
        charactersIgnoringModifiers,
        keyCode: keyCode,
        asciiCharacterProvider: asciiCharacterProvider
    )

    if keyCode == 53 {
        return .exit
    }

    switch keyCode {
    case 126:
        return .adjustSelection(.up)
    case 125:
        return .adjustSelection(.down)
    case 123:
        return .adjustSelection(.left)
    case 124:
        return .adjustSelection(.right)
    case 116:
        return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
    case 121:
        return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
    case 115:
        return hasSelection ? .adjustSelection(.home) : .scrollToTop
    case 119:
        return hasSelection ? .adjustSelection(.end) : .scrollToBottom
    default:
        break
    }

    if normalized == [.control] {
        if chars == "u" || chars == "\u{15}" {
            return hasSelection ? .adjustSelection(.pageUp) : .scrollHalfPage(-1)
        }
        if chars == "d" || chars == "\u{04}" {
            return hasSelection ? .adjustSelection(.pageDown) : .scrollHalfPage(1)
        }
        if chars == "b" || chars == "\u{02}" {
            return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
        }
        if chars == "f" || chars == "\u{06}" {
            return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
        }
        if chars == "y" || chars == "\u{19}" {
            return hasSelection ? .adjustSelection(.up) : .scrollLines(-1)
        }
        if chars == "e" || chars == "\u{05}" {
            return hasSelection ? .adjustSelection(.down) : .scrollLines(1)
        }
        return nil
    }

    guard normalized.isEmpty || normalized == [.shift] else { return nil }

    switch chars {
    case "q":
        return .exit
    case "v":
        return hasSelection ? .clearSelection : .startSelection
    case "y":
        if normalized == [.shift], !hasSelection {
            return .copyLineAndExit
        }
        return hasSelection ? .copyAndExit : nil
    case "j":
        return .adjustSelection(.down)
    case "k":
        return .adjustSelection(.up)
    case "h":
        return .adjustSelection(.left)
    case "l":
        return .adjustSelection(.right)
    case "g":
        if normalized == [.shift] {
            return hasSelection ? .adjustSelection(.end) : .scrollToBottom
        }
        return nil
    case "0", "^":
        return .adjustSelection(.beginningOfLine)
    case "$", "4":
        guard chars == "$" || normalized == [.shift] else { return nil }
        return .adjustSelection(.endOfLine)
    case "{", "[":
        guard chars == "{" || normalized == [.shift] else { return nil }
        return .jumpToPrompt(-1)
    case "}", "]":
        guard chars == "}" || normalized == [.shift] else { return nil }
        return .jumpToPrompt(1)
    case "/":
        return .startSearch
    case "n":
        return normalized == [.shift] ? .searchPrevious : .searchNext
    default:
        return nil
    }
}

/// Resolves a key event and any pending prefix state to a copy-mode command.
///
/// This is the stateful resolver used by the terminal host. It consumes numeric
/// prefixes, tracks pending `gg` and `yy` sequences in
/// ``TerminalKeyboardCopyModeInputState``, and returns either a counted action or
/// a consume-only result.
///
/// ```swift
/// var state = TerminalKeyboardCopyModeInputState()
/// _ = terminalKeyboardCopyModeResolve(
///     keyCode: 20,
///     charactersIgnoringModifiers: "3",
///     modifiers: [],
///     hasSelection: false,
///     state: &state
/// )
/// let result = terminalKeyboardCopyModeResolve(
///     keyCode: 38,
///     charactersIgnoringModifiers: "j",
///     modifiers: [],
///     hasSelection: false,
///     state: &state
/// )
/// ```
///
/// - Parameters:
///   - keyCode: The hardware key code for the event.
///   - charactersIgnoringModifiers: The layout character reported without modifiers.
///   - modifiers: The event modifiers converted to ``TerminalKeyboardCopyModeModifiers``.
///   - hasSelection: Whether visual selection is currently active.
///   - state: The pending multi-key input state to read and update.
///   - asciiCharacterProvider: A fallback physical-key lookup for non-ASCII input sources.
/// - Returns: A resolution describing whether to perform or only consume the event.
public func terminalKeyboardCopyModeResolve(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifiers: TerminalKeyboardCopyModeModifiers,
    hasSelection: Bool,
    state: inout TerminalKeyboardCopyModeInputState,
    asciiCharacterProvider: (UInt16) -> String? = { _ in nil }
) -> TerminalKeyboardCopyModeResolution {
    let normalized = terminalKeyboardCopyModeNormalizedModifiers(modifiers)
    let chars = terminalKeyboardCopyModeChars(
        charactersIgnoringModifiers,
        keyCode: keyCode,
        asciiCharacterProvider: asciiCharacterProvider
    )

    if keyCode == 53 {
        state.reset()
        return .perform(.exit, count: 1)
    }

    if state.pendingYankLine {
        if chars == "y", normalized.isEmpty || normalized == [.shift] {
            let count = terminalKeyboardCopyModeClampCount(state.countPrefix ?? 1)
            state.reset()
            return .perform(.copyLineAndExit, count: count)
        }
        state.reset()
    }

    if state.pendingG {
        if chars == "g", normalized.isEmpty {
            let count = terminalKeyboardCopyModeClampCount(state.countPrefix ?? 1)
            let action: TerminalKeyboardCopyModeAction = hasSelection ? .adjustSelection(.home) : .scrollToTop
            state.reset()
            return .perform(action, count: count)
        }
        state.reset()
    }

    if normalized.isEmpty,
       let scalar = chars.unicodeScalars.first,
       scalar.isASCII,
       scalar.value >= 48,
       scalar.value <= 57 {
        let digit = Int(scalar.value - 48)
        if digit == 0 {
            if let currentCount = state.countPrefix {
                state.countPrefix = terminalKeyboardCopyModeClampCount(currentCount * 10)
                return .consume
            }
        } else {
            let currentCount = state.countPrefix ?? 0
            state.countPrefix = terminalKeyboardCopyModeClampCount((currentCount * 10) + digit)
            return .consume
        }
    }

    if !hasSelection, chars == "y", normalized.isEmpty {
        state.pendingYankLine = true
        return .consume
    }

    if chars == "g", normalized.isEmpty {
        state.pendingG = true
        return .consume
    }

    guard let action = terminalKeyboardCopyModeAction(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: modifiers,
        hasSelection: hasSelection,
        asciiCharacterProvider: asciiCharacterProvider
    ) else {
        state.reset()
        return .consume
    }

    let count = terminalKeyboardCopyModeClampCount(state.countPrefix ?? 1)
    state.reset()
    return .perform(action, count: count)
}

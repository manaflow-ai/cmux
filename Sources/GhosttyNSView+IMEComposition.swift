import AppKit
import Carbon.HIToolbox

extension GhosttyNSView {
    // Issue #4093 is specifically Korean 2-Set. Other Korean layouts should be
    // validated separately before this allow-list is broadened.
    private static let korean2SetInputSourceIDs: Set<String> = [
        "com.apple.inputmethod.Korean.2SetKorean",
    ]

    /// Clamps AppKit's marked-text selection into the active preedit buffer.
    func normalizedMarkedSelectionRange(_ range: NSRange, markedLength: Int) -> NSRange {
        guard markedLength > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }
        guard range.location != NSNotFound else {
            return NSRange(location: markedLength, length: 0)
        }

        let clampedLocation = min(max(range.location, 0), markedLength)
        let clampedLength = min(max(range.length, 0), markedLength - clampedLocation)
        return NSRange(location: clampedLocation, length: clampedLength)
    }

    /// Clamps an AppKit substring query so it can be served from marked text.
    func clampedMarkedTextRange(_ range: NSRange, markedLength: Int) -> NSRange? {
        guard range.length > 0, range.location != NSNotFound else { return nil }
        guard markedLength > 0 else { return nil }

        let location = min(max(range.location, 0), markedLength)
        let maxLength = markedLength - location
        guard maxLength > 0 else { return nil }

        let length = min(max(range.length, 0), maxLength)
        guard length > 0 else { return nil }
        return NSRange(location: location, length: length)
    }

    /// Returns true when AppKit consumed the key by changing IME composition state.
    func shouldSuppressGhosttyKeyForwardingAfterIMEHandling(
        before: (text: String, selection: NSRange),
        after: (text: String, selection: NSRange),
        accumulatedText: [String],
        event: NSEvent? = nil,
        inputSourceId: String? = nil
    ) -> Bool {
        guard accumulatedText.isEmpty else { return false }

        let hadMarkedTextBefore = !before.text.isEmpty
        let hasMarkedTextAfter = !after.text.isEmpty
        guard hadMarkedTextBefore || hasMarkedTextAfter else { return false }

        if before.text != after.text {
            return true
        }

        if before.selection != after.selection {
            return !shouldForwardKoreanMarkedSelectionArrowToTerminal(
                event: event,
                inputSourceId: inputSourceId
            )
        }

        guard let event, isInputMethodSource(inputSourceId) else {
            return false
        }
        guard !shouldForwardKoreanMarkedSelectionArrowToTerminal(
            event: event,
            inputSourceId: inputSourceId
        ) else {
            return false
        }
        return shouldKeepIMECompositionCommandInsideTextInput(event)
    }

    private func shouldForwardKoreanMarkedSelectionArrowToTerminal(
        event: NSEvent?,
        inputSourceId: String?
    ) -> Bool {
        guard let event else { return false }
        guard isKorean2SetInputSource(inputSourceId) else { return false }
        guard hasOnlyPlainTextInputModifiers(event) else { return false }

        switch Int(event.keyCode) {
        case kVK_LeftArrow, kVK_RightArrow:
            return true
        default:
            return false
        }
    }

    private func isKorean2SetInputSource(_ inputSourceId: String?) -> Bool {
        guard let inputSourceId else { return false }
        return Self.korean2SetInputSourceIDs.contains(inputSourceId)
    }

    private func isInputMethodSource(_ inputSourceId: String?) -> Bool {
        guard let inputSourceId else { return false }
        return inputSourceId.range(
            of: ".inputmethod.",
            options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil
    }

    private func isBopomofoInputSource(_ inputSourceId: String?) -> Bool {
        guard let inputSourceId else { return false }
        let comparisonLocale = Locale(identifier: "en_US_POSIX")
        return inputSourceId.range(of: "Zhuyin", options: .caseInsensitive, locale: comparisonLocale) != nil
            || inputSourceId.range(of: "Bopomofo", options: .caseInsensitive, locale: comparisonLocale) != nil
    }

    private func hasOnlyPlainTextInputModifiers(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        return flags.isEmpty
    }

    /// Returns true for active-composition command keys that belong to AppKit's
    /// text input manager even when marked text itself does not change.
    private func shouldKeepIMECompositionCommandInsideTextInput(_ event: NSEvent) -> Bool {
        guard hasOnlyTextInputCommandModifiers(event) else { return false }

        switch Int(event.keyCode) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End,
             kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape,
             kVK_Tab, kVK_Delete, kVK_ForwardDelete:
            return true
        default:
            return false
        }
    }

    private func hasOnlyTextInputCommandModifiers(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        return flags.isEmpty || flags == [.shift]
    }

    /// When `macos-option-as-alt` strips Option for terminal fallback encoding,
    /// AppKit still needs the original Option event for dead-key composition
    /// (`Option+n` then `a` -> `ã`). Use the original event only for text
    /// interpretation; Ghostty fallback continues to use the translated event.
    func textInputInterpretationEvent(original event: NSEvent, translated translationEvent: NSEvent) -> NSEvent {
        shouldPreserveOriginalOptionDeadKeyEvent(
            original: event,
            translated: translationEvent
        ) ? event : translationEvent
    }

    private func shouldPreserveOriginalOptionDeadKeyEvent(
        original event: NSEvent,
        translated translationEvent: NSEvent
    ) -> Bool {
        let originalFlags = textInputRelevantFlags(event.modifierFlags)
        let translatedFlags = textInputRelevantFlags(translationEvent.modifierFlags)

        guard originalFlags.contains(.option),
              !translatedFlags.contains(.option),
              !originalFlags.contains(.command),
              !originalFlags.contains(.control) else {
            return false
        }

        guard (event.characters ?? "").isEmpty,
              let unmodifiedText = event.charactersIgnoringModifiers,
              unmodifiedText.count == 1,
              let scalar = unmodifiedText.unicodeScalars.first else {
            return false
        }

        return scalar.value >= 0x20
            && scalar.value != 0x7F
            && !(0xF700...0xF8FF).contains(scalar.value)
    }

    private func textInputRelevantFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
    }

    func shouldBufferBopomofoInsertedPreedit(_ text: String, inputSourceId: String? = nil) -> Bool {
        guard !text.isEmpty else { return false }
        guard isBopomofoInputSource(inputSourceId ?? KeyboardLayout.id) else { return false }
        return text.unicodeScalars.allSatisfy(isBopomofoPreeditScalar)
    }

    private func isBopomofoPreeditScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3100...0x312F, 0x31A0...0x31BF:
            return true
        case 0x02C7, 0x02C9, 0x02CA, 0x02CB, 0x02D9:
            return true
        default:
            return false
        }
    }

#if DEBUG
    func shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
        markedTextBefore: String,
        markedSelectionBefore: NSRange,
        markedTextAfter: String,
        markedSelectionAfter: NSRange,
        accumulatedText: [String],
        event: NSEvent? = nil,
        inputSourceId: String? = nil
    ) -> Bool {
        shouldSuppressGhosttyKeyForwardingAfterIMEHandling(
            before: (markedTextBefore, markedSelectionBefore),
            after: (markedTextAfter, markedSelectionAfter),
            accumulatedText: accumulatedText,
            event: event,
            inputSourceId: inputSourceId
        )
    }
#endif
}

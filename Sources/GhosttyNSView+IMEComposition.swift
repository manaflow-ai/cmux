import AppKit
import Carbon.HIToolbox

extension GhosttyNSView {
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
        textInputHandledEvent: Bool = false,
        inputSourceId: String? = nil
    ) -> Bool {
        guard accumulatedText.isEmpty else { return false }

        let hadMarkedTextBefore = !before.text.isEmpty
        let hasMarkedTextAfter = !after.text.isEmpty
        guard hadMarkedTextBefore || hasMarkedTextAfter else {
            guard textInputHandledEvent else { return false }
            return shouldKeepNoMarkedIMECommandInsideTextInput(event, inputSourceId: inputSourceId)
        }

        if before.text != after.text {
            return true
        }

        if before.selection != after.selection {
            return true
        }

        guard let event, isInputMethodSource(inputSourceId) else {
            return false
        }
        return shouldKeepIMECompositionCommandInsideTextInput(event)
    }

    func isInputMethodSource(_ sourceId: String?) -> Bool {
        IMECommandPolicy(inputSourceId: sourceId).isInputMethod
    }

    func hasOnlyTextInputCommandModifiers(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        return flags.isEmpty || flags == [.shift]
    }

    func shouldKeepNoMarkedIMECommandInsideTextInput(_ event: NSEvent?, inputSourceId: String?) -> Bool {
        guard let event else { return false }
        guard hasOnlyTextInputCommandModifiers(event) else { return false }

        return IMECommandPolicy(inputSourceId: inputSourceId)
            .keepsNoMarkedHandledCommandInsideTextInput(keyCode: Int(event.keyCode))
    }

    /// Returns true when a window-level key-equivalent probe should re-enter
    /// the terminal's keyDown path so AppKit's text input context sees the key
    /// before terminal bindings or cursor escape sequences do.
    func shouldRouteTextInputKeyEquivalentToKeyDown(_ event: NSEvent) -> Bool {
        shouldRouteTextInputKeyEquivalentToKeyDown(event, inputSourceId: nil)
    }

    func shouldRouteTextInputKeyEquivalentToKeyDown(_ event: NSEvent, inputSourceId: String?) -> Bool {
        guard event.type == .keyDown else { return false }
        let resolvedInputSourceId = inputSourceId ?? KeyboardLayout.id
        if hasMarkedText() {
            return isInputMethodSource(resolvedInputSourceId)
                && shouldKeepIMECompositionCommandInsideTextInput(event)
        }
        return shouldKeepNoMarkedIMECommandInsideTextInput(
            event,
            inputSourceId: resolvedInputSourceId
        )
    }

    /// Returns true for active-composition command keys that belong to AppKit's
    /// text input manager even when marked text itself does not change.
    func shouldKeepIMECompositionCommandInsideTextInput(_ event: NSEvent) -> Bool {
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

    private enum IMECommandPolicy {
        case nonInputMethod
        case otherInputMethod
        case bopomofoCandidate
        case applePinyinCandidate

        init(inputSourceId: String?) {
            guard let inputSourceId else {
                self = .nonInputMethod
                return
            }

            if inputSourceId.localizedCaseInsensitiveContains("Zhuyin")
                || inputSourceId.localizedCaseInsensitiveContains("Bopomofo") {
                self = .bopomofoCandidate
                return
            }

            if inputSourceId == "com.apple.inputmethod.SCIM.ITABC"
                || inputSourceId == "com.apple.inputmethod.TCIM.Pinyin" {
                self = .applePinyinCandidate
                return
            }

            if inputSourceId.localizedCaseInsensitiveContains("inputmethod") {
                self = .otherInputMethod
                return
            }

            self = .nonInputMethod
        }

        var isInputMethod: Bool {
            switch self {
            case .bopomofoCandidate, .applePinyinCandidate, .otherInputMethod:
                return true
            case .nonInputMethod:
                return false
            }
        }

        func keepsNoMarkedHandledCommandInsideTextInput(keyCode: Int) -> Bool {
            switch self {
            case .nonInputMethod, .otherInputMethod:
                return false
            case .bopomofoCandidate:
                switch keyCode {
                case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                     kVK_PageUp, kVK_PageDown, kVK_Space:
                    return true
                default:
                    return false
                }
            case .applePinyinCandidate:
                switch keyCode {
                case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                     kVK_PageUp, kVK_PageDown, kVK_Tab:
                    return true
                default:
                    return false
                }
            }
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
        textInputHandledEvent: Bool = false,
        inputSourceId: String? = nil
    ) -> Bool {
        shouldSuppressGhosttyKeyForwardingAfterIMEHandling(
            before: (markedTextBefore, markedSelectionBefore),
            after: (markedTextAfter, markedSelectionAfter),
            accumulatedText: accumulatedText,
            event: event,
            textInputHandledEvent: textInputHandledEvent,
            inputSourceId: inputSourceId
        )
    }
#endif
}

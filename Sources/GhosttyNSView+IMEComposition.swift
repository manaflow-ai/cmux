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
            return !shouldForwardMarkedSelectionCommandToTerminal(
                event: event,
                inputSourceId: inputSourceId
            )
        }

        guard let event, isInputMethodSource(inputSourceId) else {
            return false
        }
        guard !shouldForwardMarkedSelectionCommandToTerminal(
            event: event,
            inputSourceId: inputSourceId
        ) else {
            return false
        }
        return shouldKeepIMECompositionCommandInsideTextInput(event)
    }

    private func isInputMethodSource(_ inputSourceId: String?) -> Bool {
        IMECommandPolicy(inputSourceId: inputSourceId).isInputMethod
    }

    private func shouldForwardMarkedSelectionCommandToTerminal(
        event: NSEvent?,
        inputSourceId: String?
    ) -> Bool {
        guard let event else { return false }
        return IMECommandPolicy(inputSourceId: inputSourceId)
            .forwardsMarkedSelectionCommandToTerminal(event)
    }

    private func shouldKeepNoMarkedIMECommandInsideTextInput(
        _ event: NSEvent?,
        inputSourceId: String?
    ) -> Bool {
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

    func shouldRouteTextInputKeyEquivalentToKeyDown(
        _ event: NSEvent,
        inputSourceId: String?
    ) -> Bool {
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

    func shouldBufferBopomofoInsertedPreedit(_ text: String, inputSourceId: String? = nil) -> Bool {
        IMECommandPolicy(inputSourceId: inputSourceId ?? KeyboardLayout.id)
            .buffersInsertedPreedit(text)
    }

    private enum IMECommandPolicy {
        case nonInputMethod
        case otherInputMethod
        case bopomofoCandidate
        case applePinyinCandidate
        case korean2Set

        init(inputSourceId: String?) {
            guard let inputSourceId else {
                self = .nonInputMethod
                return
            }

            if GhosttyNSView.korean2SetInputSourceIDs.contains(inputSourceId) {
                self = .korean2Set
                return
            }

            let comparisonLocale = Locale(identifier: "en_US_POSIX")
            if inputSourceId.range(of: "Zhuyin", options: .caseInsensitive, locale: comparisonLocale) != nil
                || inputSourceId.range(of: "Bopomofo", options: .caseInsensitive, locale: comparisonLocale) != nil {
                self = .bopomofoCandidate
                return
            }

            if inputSourceId == "com.apple.inputmethod.SCIM.ITABC"
                || inputSourceId == "com.apple.inputmethod.TCIM.Pinyin" {
                self = .applePinyinCandidate
                return
            }

            if inputSourceId.range(
                of: ".inputmethod.",
                options: .caseInsensitive,
                locale: comparisonLocale
            ) != nil {
                self = .otherInputMethod
                return
            }

            self = .nonInputMethod
        }

        var isInputMethod: Bool {
            switch self {
            case .bopomofoCandidate, .applePinyinCandidate, .korean2Set, .otherInputMethod:
                return true
            case .nonInputMethod:
                return false
            }
        }

        func keepsNoMarkedHandledCommandInsideTextInput(keyCode: Int) -> Bool {
            switch self {
            case .nonInputMethod, .otherInputMethod, .korean2Set:
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

        func forwardsMarkedSelectionCommandToTerminal(_ event: NSEvent) -> Bool {
            guard case .korean2Set = self else { return false }
            guard Self.hasOnlyPlainTextInputModifiers(event) else { return false }

            switch Int(event.keyCode) {
            case kVK_LeftArrow, kVK_RightArrow:
                return true
            default:
                return false
            }
        }

        func buffersInsertedPreedit(_ text: String) -> Bool {
            guard case .bopomofoCandidate = self else { return false }
            guard !text.isEmpty else { return false }
            return text.unicodeScalars.allSatisfy(Self.isBopomofoPreeditScalar)
        }

        private static func hasOnlyPlainTextInputModifiers(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            return flags.isEmpty
        }

        private static func isBopomofoPreeditScalar(_ scalar: UnicodeScalar) -> Bool {
            switch scalar.value {
            case 0x3100...0x312F, 0x31A0...0x31BF:
                return true
            case 0x02C7, 0x02C9, 0x02CA, 0x02CB, 0x02D9:
                return true
            default:
                return false
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

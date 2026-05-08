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
            // Some IMEs, including Traditional Chinese Zhuyin, can handle a
            // command key against their private preedit buffer before they call
            // setMarkedText on the client. Keep handled no-output input-method
            // events out of the terminal so keys such as Down can open
            // candidates instead of moving the shell cursor.
            guard textInputHandledEvent, isInputMethodSource(inputSourceId) else { return false }
            return !shouldAllowDeferredNumpadIMEFallback(event)
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
        guard let sourceId else { return false }
        return sourceId.localizedCaseInsensitiveContains("inputmethod")
    }

    func shouldAllowDeferredNumpadIMEFallback(_ event: NSEvent?) -> Bool {
        guard let event,
              let text = event.characters,
              !text.isEmpty,
              text.allSatisfy(\.isNumber) else {
            return false
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .capsLock])
        return flags == [.numericPad]
    }

    func isTraditionalZhuyinInputSource(_ sourceId: String?) -> Bool {
        guard let sourceId else { return false }
        return sourceId.localizedCaseInsensitiveContains("TCIM.Zhuyin")
    }

    func shouldOpenZhuyinCandidatesWithSyntheticSpace(
        event: NSEvent,
        inputSourceId: String?,
        markedTextBefore: Bool,
        before: (text: String, selection: NSRange),
        after: (text: String, selection: NSRange),
        accumulatedText: [String],
        commandSelector: Selector?,
        candidateOpenAlreadyRequested: Bool
    ) -> Bool {
        guard !candidateOpenAlreadyRequested,
              markedTextBefore,
              accumulatedText.isEmpty,
              isTraditionalZhuyinInputSource(inputSourceId),
              Int(event.keyCode) == kVK_DownArrow,
              commandSelector == #selector(NSResponder.moveDown(_:)),
              before.text == after.text,
              before.selection == after.selection else {
            return false
        }
        return true
    }

    func shouldRememberZhuyinCandidateInteraction(
        event: NSEvent,
        inputSourceId: String?,
        markedTextBefore: Bool,
        accumulatedText: [String]
    ) -> Bool {
        guard markedTextBefore,
              accumulatedText.isEmpty,
              isTraditionalZhuyinInputSource(inputSourceId) else {
            return false
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty || flags == [.shift] else { return false }

        switch Int(event.keyCode) {
        case kVK_DownArrow, kVK_UpArrow, kVK_PageUp, kVK_PageDown, kVK_Space:
            return true
        default:
            return false
        }
    }

    /// Returns true for active-composition command keys that belong to AppKit's
    /// text input manager even when marked text itself does not change.
    func shouldKeepIMECompositionCommandInsideTextInput(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty || flags == [.shift] else { return false }

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

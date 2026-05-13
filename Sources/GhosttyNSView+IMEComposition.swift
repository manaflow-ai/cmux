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

        return false
    }

    func shouldRouteKoreanMarkedSelectionArrowKeyEquivalentToKeyDown(_ event: NSEvent) -> Bool {
        guard hasMarkedText() else { return false }
        return shouldForwardKoreanMarkedSelectionArrowToTerminal(
            event: event,
            inputSourceId: KeyboardLayout.id
        )
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
        return inputSourceId.localizedCaseInsensitiveContains("Korean.2Set")
            || inputSourceId.localizedCaseInsensitiveContains("2SetKorean")
    }

    private func hasOnlyPlainTextInputModifiers(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        return flags.isEmpty
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

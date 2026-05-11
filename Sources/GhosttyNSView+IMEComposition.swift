import AppKit
import Carbon.HIToolbox

extension GhosttyNSView {
    private static let appleTraditionalZhuyinInputSourceId = "com.apple.inputmethod.TCIM.Zhuyin"

    private func isAppleTraditionalZhuyinInputSource(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.compare(Self.appleTraditionalZhuyinInputSourceId, options: [.caseInsensitive]) == .orderedSame
    }

    /// Returns true for the narrow #3691 path where AppKit's Zhuyin candidate UI owns the arrow.
    func shouldRouteKeyToZhuyinCandidateInsteadOfTerminal(
        event: NSEvent,
        inputSourceId: String?
    ) -> Bool {
        guard hasMarkedText() else { return false }
        guard isAppleTraditionalZhuyinInputSource(inputSourceId) else { return false }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return false }

        switch Int(event.keyCode) {
        case kVK_DownArrow, kVK_UpArrow:
            return true
        default:
            return false
        }
    }

    /// Returns true when a plain Zhuyin Down arrow reached AppKit text input but did not mutate
    /// composition state, so the OS input method still needs the candidate-list expansion gesture.
    func shouldExpandZhuyinCandidatesAfterTextInterpretation(
        event: NSEvent,
        inputSourceId: String?,
        before: (text: String, selection: NSRange),
        after: (text: String, selection: NSRange),
        accumulatedText: [String],
        commandSelector: Selector?
    ) -> Bool {
        guard !before.text.isEmpty else { return false }
        guard hasMarkedText() else { return false }
        guard isAppleTraditionalZhuyinInputSource(inputSourceId) else { return false }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return false }
        guard Int(event.keyCode) == kVK_DownArrow else { return false }
        guard commandSelector == #selector(NSResponder.moveDown(_:)) else { return false }
        guard accumulatedText.isEmpty else { return false }

        return before.text == after.text && before.selection == after.selection
    }

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
        accumulatedText: [String]
    ) -> Bool {
        guard accumulatedText.isEmpty else { return false }

        let hadMarkedTextBefore = !before.text.isEmpty
        let hasMarkedTextAfter = !after.text.isEmpty
        guard hadMarkedTextBefore || hasMarkedTextAfter else { return false }

        if before.text != after.text {
            return true
        }

        return before.selection != after.selection
    }

#if DEBUG
    func shouldSuppressGhosttyKeyForwardingAfterIMEHandlingForTesting(
        markedTextBefore: String,
        markedSelectionBefore: NSRange,
        markedTextAfter: String,
        markedSelectionAfter: NSRange,
        accumulatedText: [String]
    ) -> Bool {
        shouldSuppressGhosttyKeyForwardingAfterIMEHandling(
            before: (markedTextBefore, markedSelectionBefore),
            after: (markedTextAfter, markedSelectionAfter),
            accumulatedText: accumulatedText
        )
    }
#endif
}

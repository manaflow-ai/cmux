import AppKit

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

    /// Uses libghostty's translated modifiers as the sole terminal text policy.
    ///
    /// AppKit still owns composition through `interpretKeyEvents`; this method
    /// prevents the host from silently restoring modifiers that libghostty
    /// intentionally removed for terminal input.
    func textInputInterpretationEvent(
        original _: NSEvent,
        translated translationEvent: NSEvent
    ) -> NSEvent {
        translationEvent
    }
}

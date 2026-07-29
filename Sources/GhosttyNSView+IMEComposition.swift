import AppKit
import Carbon.HIToolbox

extension GhosttyNSView {
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
    /// AppKit still owns composition through its text input context; this method
    /// prevents the host from silently restoring modifiers that libghostty
    /// intentionally removed for terminal input.
    func textInputInterpretationEvent(
        original _: NSEvent,
        translated translationEvent: NSEvent
    ) -> NSEvent {
        translationEvent
    }

    /// Mirrors Ghostty's locale-independent post-commit navigation policy.
    ///
    /// Most keys only cause AppKit to commit preedit text. Directional
    /// navigation can additionally affect the terminal after that commit.
    func replaysPhysicalKeyAfterPreeditCommit(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_DownArrow, kVK_RightArrow, kVK_UpArrow:
            return true
        case kVK_LeftArrow:
            return !event.modifierFlags.isDisjoint(
                with: [.shift, .control, .option, .command]
            )
        default:
            return false
        }
    }

}

import AppKit

/// Stop control that preserves terminal focus behavior and uses the pointing cursor.
final class TerminalAgentTurnControlButton: NSButton {
    override var acceptsFirstResponder: Bool { false }

    /// Stop works on the first click even when the window isn't key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

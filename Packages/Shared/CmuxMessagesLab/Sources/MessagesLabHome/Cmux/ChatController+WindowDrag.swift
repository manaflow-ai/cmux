import AppKit

// cmux: the floating Chief's own window moves from a press on the chat's empty space (red: not yet).
extension ChatController {
    /// Whether a press at `p` (host coordinates) lands on nothing the chat acts on.
    func isEmptySpace(at p: CGPoint) -> Bool { false }

    /// Whether a press at `windowPoint` on `hit` moves the window; nil when `hit` is not the transcript's.
    func pressMovesWindow(atWindowPoint windowPoint: CGPoint, hit: NSView) -> Bool? { nil }
}

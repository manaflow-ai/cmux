/// Coalesces terminal-grid mutation signals into one post-render scan request.
struct TerminalInlineImageRenderedFrameGate: Sendable {
    private var hasPendingGridMutation = false

    mutating func noteGridMutation() {
        hasPendingGridMutation = true
    }

    mutating func consumeRenderedFrame() -> Bool {
        guard hasPendingGridMutation else { return false }
        hasPendingGridMutation = false
        return true
    }

    mutating func reset() {
        hasPendingGridMutation = false
    }
}

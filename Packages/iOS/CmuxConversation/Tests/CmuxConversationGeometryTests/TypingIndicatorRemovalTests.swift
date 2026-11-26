import CmuxConversationGeometry
import Testing

struct TypingIndicatorRemovalTests {
    /// ChatKit stops the pulse before the row fades and holds the dots at
    /// `thinkingDotOpacity` (read live from `CKTypingIndicatorLayer` on the
    /// iOS 26.5 and 27.0 simulators).
    @Test func removalStopsPulseAndHoldsDots() {
        let removal = TypingIndicatorRemoval.messages
        #expect(removal.keepsPulse == false)
        #expect(removal.heldDotOpacity == 0.45)
    }
}

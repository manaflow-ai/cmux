import CmuxConversationGeometry
import CoreGraphics
import Testing

/// iPhone 17 Pro portrait: 874 pt tall, 34 pt home-indicator inset, a 335 pt
/// docked keyboard.
@Suite struct ConversationKeyboardPinGeometryTests {
    let screenBottom: CGFloat = 874
    let restingGuideTop: CGFloat = 840
    let dockedTop: CGFloat = 539

    /// The composer's bottom edge for a keyboard top edge, as the view lays it out.
    func composerBottom(keyboardTop: CGFloat, guideTop: CGFloat) -> CGFloat {
        guideTop - 4 + ConversationKeyboardPinGeometry.drop(keyboardTop: keyboardTop, guideTop: guideTop, restingGuideTop: restingGuideTop)
    }

    @Test func endStatesMatchMessages() {
        let rest = composerBottom(keyboardTop: screenBottom, guideTop: restingGuideTop)
        #expect(rest == 850)
        let docked = composerBottom(keyboardTop: dockedTop, guideTop: dockedTop)
        #expect(docked == dockedTop - 12)
    }

    /// The finger drags the keyboard: the guide follows it down to the safe
    /// area, then stops; the composer stays 12 pt above the keyboard all
    /// the way and settles at rest without a step.
    @Test func composerRidesTheKeyboardThroughAnInteractiveDismissal() {
        var previous = -CGFloat.infinity
        for finger in stride(from: dockedTop, through: screenBottom, by: 0.5) {
            let guideTop = min(finger, restingGuideTop)
            let top = ConversationKeyboardPinGeometry.keyboardTop(
                guideTop: guideTop, restingGuideTop: restingGuideTop, screenBottom: screenBottom, dragLocation: finger
            )
            #expect(top == finger)
            let bottom = composerBottom(keyboardTop: finger, guideTop: guideTop)
            #expect(bottom == min(finger - 12, 850))
            #expect(bottom >= previous)
            #expect(bottom - previous <= 0.5 || previous == -.infinity)
            previous = bottom
        }
    }

    @Test func fingerAboveTheKeyboardLeavesItDocked() {
        let top = ConversationKeyboardPinGeometry.keyboardTop(
            guideTop: dockedTop, restingGuideTop: restingGuideTop, screenBottom: screenBottom, dragLocation: 300
        )
        #expect(top == dockedTop)
    }

    /// Letting go mid-keyboard: UIKit returns the guide to rest before it
    /// animates the keyboard away, so the composer holds still.
    @Test func releaseHoldsUntilTheKeyboardAnimates() {
        let top = ConversationKeyboardPinGeometry.keyboardTop(
            guideTop: restingGuideTop, restingGuideTop: restingGuideTop, screenBottom: screenBottom, dragLocation: 653
        )
        #expect(top == nil)
    }

    @Test func noKeyboardMeansRest() {
        let top = ConversationKeyboardPinGeometry.keyboardTop(
            guideTop: restingGuideTop, restingGuideTop: restingGuideTop, screenBottom: screenBottom, dragLocation: nil
        )
        #expect(top == screenBottom)
        #expect(composerBottom(keyboardTop: screenBottom, guideTop: restingGuideTop) == 850)
    }

    /// A hardware keyboard's bar (or a shorter keyboard) that stays below the
    /// resting composer leaves it at rest.
    @Test func shortKeyboardBelowTheComposerLeavesItAtRest() {
        #expect(composerBottom(keyboardTop: 866, guideTop: restingGuideTop) == 850)
        #expect(composerBottom(keyboardTop: 860, guideTop: restingGuideTop) == 848)
    }
}

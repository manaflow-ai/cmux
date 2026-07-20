#if os(iOS)
@testable import CmuxMobileShellUI
import SwiftUI
import Testing

@Suite struct OnboardingTransitionDirectionTests {
    @Test func advancingStagesPushFromTrailingEdge() {
        let firstTransition = OnboardingTransitionDirection(
            from: .agents,
            to: .reserved
        )
        let secondTransition = OnboardingTransitionDirection(
            from: .reserved,
            to: .connect
        )

        #expect(firstTransition == .forward)
        #expect(firstTransition.pushEdge == .trailing)
        #expect(secondTransition == .forward)
        #expect(secondTransition.pushEdge == .trailing)
    }

    @Test func retreatingStagesPushFromLeadingEdge() {
        let firstTransition = OnboardingTransitionDirection(
            from: .connect,
            to: .reserved
        )
        let secondTransition = OnboardingTransitionDirection(
            from: .reserved,
            to: .agents
        )

        #expect(firstTransition == .backward)
        #expect(firstTransition.pushEdge == .leading)
        #expect(secondTransition == .backward)
        #expect(secondTransition.pushEdge == .leading)
    }
}
#endif

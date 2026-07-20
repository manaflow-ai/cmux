#if os(iOS)
import SwiftUI

struct OnboardingPageViewport<PageContent: View>: View {
    let stage: OnboardingStage
    let transitionDirection: OnboardingTransitionDirection
    let pageContent: PageContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            pageContent
                .id(stage)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingPageViewport")
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .identity : .push(from: transitionDirection.pushEdge)
    }
}
#endif

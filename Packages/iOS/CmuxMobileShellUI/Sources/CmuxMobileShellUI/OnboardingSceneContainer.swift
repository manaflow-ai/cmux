#if os(iOS)
import SwiftUI

struct OnboardingSceneContainer<PageContent: View>: View {
    let stage: OnboardingStage
    let chrome: OnboardingSceneChrome
    let onBack: () -> Void
    let onSkip: () -> Void
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let pageContent: PageContent

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            VStack(spacing: 0) {
                OnboardingSceneHeader(
                    stage: stage,
                    showsBack: chrome.showsBack,
                    showsSkip: chrome.showsSkip,
                    onBack: onBack,
                    onSkip: onSkip
                )

                pageContent

                OnboardingSceneFooter(
                    primaryTitle: chrome.primaryTitle,
                    secondaryTitle: chrome.secondaryTitle,
                    onPrimary: onPrimary,
                    onSecondary: onSecondary
                )
            }
        }
    }
}
#endif

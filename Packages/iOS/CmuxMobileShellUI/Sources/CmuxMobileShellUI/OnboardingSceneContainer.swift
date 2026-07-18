#if os(iOS)
import SwiftUI

struct OnboardingSceneContainer<Visual: View>: View {
    let stage: OnboardingStage
    let title: String
    let message: String
    let primaryTitle: String
    let secondaryTitle: String?
    let showsBack: Bool
    let showsSkip: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let visual: Visual

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            OnboardingBackdrop()

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityIdentifier("MobileOnboarding\(stage.analyticsValue.capitalized)Scene")

            VStack(spacing: 0) {
                OnboardingSceneHeader(
                    stage: stage,
                    showsBack: showsBack,
                    showsSkip: showsSkip,
                    onBack: onBack,
                    onSkip: onSkip
                )

                ScrollView {
                    OnboardingSceneContent(
                        title: title,
                        message: message,
                        usesWideLayout: usesWideLayout,
                        visual: visual
                    )
                    .padding(.horizontal, usesWideLayout ? 48 : 24)
                    .padding(.top, usesWideLayout ? 48 : 22)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)

                OnboardingSceneFooter(
                    primaryTitle: primaryTitle,
                    secondaryTitle: secondaryTitle,
                    onPrimary: onPrimary,
                    onSecondary: onSecondary
                )
            }
        }
    }

    private var usesWideLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }
}
#endif

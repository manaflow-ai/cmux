#if os(iOS)
import SwiftUI

struct OnboardingSceneContent<Visual: View>: View {
    let title: String
    let message: String
    let visual: Visual

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            Group {
                if usesWideLayout {
                    HStack(alignment: .center, spacing: 48) {
                        OnboardingSceneCopy(title: title, message: message, alignment: .leading)
                            .frame(maxWidth: 390)
                        visual
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(maxWidth: 520)
                    }
                    .frame(maxWidth: 980)
                } else {
                    VStack(spacing: 30) {
                        OnboardingSceneCopy(title: title, message: message, alignment: .center)
                            .frame(maxWidth: 560)
                        visual
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(maxWidth: 520)
                    }
                    .frame(maxWidth: 620)
                }
            }
            .padding(.horizontal, usesWideLayout ? 48 : 24)
            .padding(.top, usesWideLayout ? 48 : 22)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var usesWideLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }
}
#endif

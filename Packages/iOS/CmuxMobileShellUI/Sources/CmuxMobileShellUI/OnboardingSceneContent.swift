#if os(iOS)
import SwiftUI

struct OnboardingSceneContent<Visual: View>: View {
    let title: String
    let message: String
    let usesWideLayout: Bool
    let visual: Visual

    var body: some View {
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
}
#endif

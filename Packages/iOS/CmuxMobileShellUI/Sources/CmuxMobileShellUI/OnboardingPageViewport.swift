#if os(iOS)
import SwiftUI

struct OnboardingPageViewport<PageContent: View>: View {
    let stage: OnboardingStage
    @ViewBuilder let pageContent: (OnboardingStage) -> PageContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(OnboardingStage.allCases, id: \.self) { pageStage in
                    pageContent(pageStage)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .clipped()
                        .allowsHitTesting(pageStage == stage)
                        .accessibilityHidden(pageStage != stage)
                }
            }
            .frame(
                width: geometry.size.width * CGFloat(OnboardingStage.allCases.count),
                alignment: .leading
            )
            .offset(x: OnboardingPageTrack.offset(
                for: stage,
                pageWidth: geometry.size.width
            ))
            .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: stage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingPageViewport")
    }
}

enum OnboardingPageTrack {
    static func offset(for stage: OnboardingStage, pageWidth: CGFloat) -> CGFloat {
        -CGFloat(stage.rawValue) * pageWidth
    }
}
#endif

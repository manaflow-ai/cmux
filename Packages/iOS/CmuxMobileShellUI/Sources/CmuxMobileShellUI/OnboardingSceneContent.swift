#if os(iOS)
import SwiftUI

/// A stationary onboarding page. The copy keeps its intrinsic height and the
/// visual consumes the remaining bounded space, so vertical drags never move
/// page content or compete with the horizontal pager.
struct OnboardingSceneContent<Visual: View>: View {
    let title: String
    let message: String
    let visual: Visual
    let bodyLineReservation: Int

    init(
        title: String,
        message: String,
        visual: Visual,
        bodyLineReservation: Int = 2
    ) {
        self.title = title
        self.message = message
        self.visual = visual
        self.bodyLineReservation = bodyLineReservation
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if usesWideLayout {
                HStack(alignment: .center, spacing: wideSpacing) {
                    OnboardingSceneCopy(
                        title: title,
                        message: message,
                        alignment: .leading,
                        bodyLineReservation: bodyLineReservation
                    )
                    .frame(maxWidth: wideCopyMaxWidth)
                        .layoutPriority(1)
                    visual
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, wideHorizontalPadding)
                .padding(.vertical, wideVerticalPadding)
                .frame(maxWidth: 980, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 18) {
                    OnboardingSceneCopy(
                        title: title,
                        message: message,
                        alignment: .center,
                        bodyLineReservation: bodyLineReservation
                    )
                    .frame(maxWidth: 560)
                        .layoutPriority(1)
                    visual
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: 620, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var usesWideLayout: Bool {
        verticalSizeClass == .compact
            || (horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize)
    }

    private var wideSpacing: CGFloat {
        verticalSizeClass == .compact ? 16 : 48
    }

    private var wideHorizontalPadding: CGFloat {
        verticalSizeClass == .compact ? 16 : 48
    }

    private var wideVerticalPadding: CGFloat {
        verticalSizeClass == .compact ? 4 : 32
    }

    private var wideCopyMaxWidth: CGFloat {
        verticalSizeClass == .compact ? 280 : 390
    }
}
#endif

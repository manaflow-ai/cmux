#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingProgressIndicator: View {
    let stage: OnboardingStage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStage.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == stage ? Color.accentColor : Color.secondary.opacity(0.24))
                    .frame(width: item == stage ? 22 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "mobile.onboarding.progressLabel",
            defaultValue: "Welcome progress"
        ))
        .accessibilityValue(progressValue)
        .accessibilityIdentifier("MobileOnboardingProgressIndicator")
    }

    private var progressValue: String {
        String(
            format: L10n.string(
                "mobile.onboarding.progressFormat",
                defaultValue: "Step %1$d of %2$d"
            ),
            stage.position,
            OnboardingStage.allCases.count
        )
    }
}
#endif

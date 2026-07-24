#if os(iOS)
import SwiftUI

struct OnboardingSceneCopy: View {
    let title: String
    let message: String
    let alignment: TextAlignment

    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: 12) {
            OnboardingBalancedText(
                title,
                role: .title,
                alignment: alignment
            )

            OnboardingBalancedText(
                message,
                role: .body,
                alignment: alignment
            )
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }
}
#endif

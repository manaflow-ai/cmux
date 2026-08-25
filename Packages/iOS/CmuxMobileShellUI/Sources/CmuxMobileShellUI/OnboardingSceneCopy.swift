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

            // The body reserves its full two-line cap so pages with one-line
            // and two-line copy hand the visual an identical remaining height
            // (the device frames then render the same size on every page).
            OnboardingBalancedText(
                message,
                role: .body,
                alignment: alignment,
                maximumNumberOfLines: 2,
                reservesMaximumLines: true
            )
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }
}
#endif

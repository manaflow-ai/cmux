#if os(iOS)
import SwiftUI

struct OnboardingSceneCopy: View {
    let title: String
    let message: String
    let alignment: TextAlignment
    let bodyLineReservation: Int

    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: 12) {
            OnboardingBalancedText(
                title,
                role: .title,
                alignment: alignment,
                maximumNumberOfLines: 2,
                reservesMaximumLines: true
            )

            // The connect choices have different body copy. Tailscale can
            // require a third line at phone width, so reserve that line for
            // every choice and keep the label's line limit in sync. This
            // makes switching methods preserve the visual's vertical anchor
            // instead of remeasuring the page around the longer copy.
            OnboardingBalancedText(
                message,
                role: .body,
                alignment: alignment,
                maximumNumberOfLines: bodyLineReservation,
                reservesMaximumLines: true
            )
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }
}
#endif

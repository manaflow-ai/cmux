#if os(iOS)
import SwiftUI

/// Preserves the second onboarding position without advertising unfinished UI.
/// A shipped feature can replace this empty content without changing the flow.
struct OnboardingReservedView: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("MobileOnboardingReservedScene")
        }
    }
}
#endif

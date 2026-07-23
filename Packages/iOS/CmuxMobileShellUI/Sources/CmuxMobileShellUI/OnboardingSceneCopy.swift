#if os(iOS)
import SwiftUI

struct OnboardingSceneCopy: View {
    let title: String
    let message: String
    let alignment: TextAlignment

    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: 12) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .tracking(-0.5)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }
}
#endif

#if os(iOS)
import SwiftUI

/// Non-blocking notice shown while no Mac connection is live. The composer
/// stays usable for drafting; submission needs a connected Mac, so the banner
/// explains the missing connection instead of the entrypoint hiding itself.
struct TaskComposerConnectionWarningBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)

            Text(message)
                .font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileTaskComposerConnectionWarning")
    }
}
#endif

#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A nonblocking recovery notice for a notification tap waiting on its Mac.
struct MobilePushConnectionUnavailableBanner: View {
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "mobile.push.connectionUnavailable.title",
                        defaultValue: "Waiting for your Mac"
                    ))
                    .font(.subheadline.weight(.semibold))

                    Text(L10n.string(
                        "mobile.push.connectionUnavailable.message",
                        defaultValue: "This notification will open when your Mac reconnects."
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer(minLength: 0)

                Button(L10n.string(
                    "mobile.push.connectionUnavailable.cancel",
                    defaultValue: "Dismiss"
                ), action: dismiss)
                .buttonStyle(.bordered)

                Button(L10n.string(
                    "mobile.push.connectionUnavailable.retry",
                    defaultValue: "Try again"
                ), action: retry)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.24), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobilePushConnectionUnavailableBanner")
    }
}
#endif

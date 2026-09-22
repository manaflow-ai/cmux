#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobilePushAlertPresentationModifier: ViewModifier {
    let coordinator: MobilePushCoordinator
    @State private var presentedAlert: MobilePushCoordinator.TabUnavailableAlert?

    func body(content: Content) -> some View {
        content
            .onChange(of: coordinator.tabUnavailableAlert, initial: true) { _, alert in
                presentedAlert = alert?.kind == .tabUnavailable ? alert : nil
            }
            .overlay(alignment: .top) {
                if coordinator.tabUnavailableAlert?.kind == .connectionUnavailable {
                    MobilePushConnectionUnavailableBanner(
                        retry: coordinator.retryPendingDeeplink,
                        dismiss: coordinator.dismissTabUnavailableAlert
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .alert(item: $presentedAlert) { alert in
                switch alert.kind {
                case .tabUnavailable:
                    Alert(
                        title: Text(L10n.string(
                            "mobile.push.tabUnavailable.title",
                            defaultValue: "Tab unavailable"
                        )),
                        message: Text(L10n.string(
                            "mobile.push.tabUnavailable.message",
                            defaultValue: "This tab is no longer available on your Mac."
                        )),
                        dismissButton: .default(Text(L10n.string(
                            "mobile.common.ok",
                            defaultValue: "OK"
                        ))) {
                            coordinator.dismissTabUnavailableAlert()
                        }
                    )
                case .connectionUnavailable:
                    Alert(title: Text(""), dismissButton: .cancel())
                }
            }
    }
}

private struct MobilePushConnectionUnavailableBanner: View {
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

extension View {
    func mobilePushAlertPresentation(
        coordinator: MobilePushCoordinator
    ) -> some View {
        modifier(MobilePushAlertPresentationModifier(coordinator: coordinator))
    }
}
#endif

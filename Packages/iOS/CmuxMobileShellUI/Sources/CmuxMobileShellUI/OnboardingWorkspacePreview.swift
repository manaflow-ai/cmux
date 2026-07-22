#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingWorkspacePreview: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 11) {
                Image("CmuxLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "mobile.onboarding.preview.computer",
                        defaultValue: "MacBook Pro"
                    ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    Text(L10n.string(
                        "mobile.onboarding.preview.activeAgents",
                        defaultValue: "3 agents active"
                    ))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                }

                Spacer()

                Label(
                    L10n.string("mobile.onboarding.preview.live", defaultValue: "Live"),
                    systemImage: "circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
            }

            Divider()
                .overlay(.white.opacity(0.12))

            VStack(spacing: 14) {
                OnboardingWorkspacePreviewRow(
                    color: .blue,
                    systemImage: "shippingbox.fill",
                    title: L10n.string(
                        "mobile.onboarding.preview.workspace.cmux",
                        defaultValue: "Fix reconnect test"
                    ),
                    subtitle: L10n.string(
                        "mobile.onboarding.preview.workspace.finished",
                        defaultValue: "Running 7 focused tests…"
                    ),
                    showsUnread: false
                )
                OnboardingWorkspacePreviewRow(
                    color: .indigo,
                    systemImage: "terminal.fill",
                    title: L10n.string(
                        "mobile.onboarding.preview.workspace.ios",
                        defaultValue: "iOS avatar tuning"
                    ),
                    subtitle: L10n.string(
                        "mobile.onboarding.preview.workspace.working",
                        defaultValue: "Agent needs your input"
                    ),
                    showsUnread: false
                )
                OnboardingWorkspacePreviewRow(
                    color: .pink,
                    systemImage: "doc.text.fill",
                    title: L10n.string(
                        "mobile.onboarding.preview.workspace.docs",
                        defaultValue: "Docs"
                    ),
                    subtitle: L10n.string(
                        "mobile.onboarding.preview.workspace.waiting",
                        defaultValue: "Drafting release notes…"
                    ),
                    showsUnread: true
                )
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingWorkspacePreview")
    }
}
#endif

#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingAgentHandoffPreview: View {
    let onRespond: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didReply = false

    var body: some View {
        VStack(spacing: 16) {
            agentMessage

            if didReply {
                replyConfirmation
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                replyAction
                    .transition(.opacity)
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
        .accessibilityIdentifier("MobileOnboardingHandoffPreview")
    }

    private var agentMessage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.indigo.gradient)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "mobile.onboarding.handoff.agent",
                        defaultValue: "Agent needs your input"
                    ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    Text(L10n.string(
                        "mobile.onboarding.handoff.workspace",
                        defaultValue: "Fix reconnect test · now"
                    ))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                }
            }

            Text(L10n.string(
                "mobile.onboarding.handoff.question",
                defaultValue: "The integration suite is flaky. How should I handle it?"
            ))
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var replyAction: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                didReply = true
            }
            onRespond()
        } label: {
            Label(
                L10n.string(
                    "mobile.onboarding.handoff.reply",
                    defaultValue: "Separate PR"
                ),
                systemImage: "arrow.up"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint(L10n.string(
            "mobile.onboarding.handoff.replyHint",
            defaultValue: "Sends the reply in this interactive preview"
        ))
        .accessibilityIdentifier("MobileOnboardingDemoReplyButton")
    }

    private var replyConfirmation: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Text(L10n.string(
                "mobile.onboarding.handoff.reply",
                defaultValue: "Separate PR"
            ))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor, in: Capsule())

            Label(
                L10n.string(
                    "mobile.onboarding.handoff.continuing",
                    defaultValue: "Continuing on your Mac"
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileOnboardingDemoReplySent")
    }
}
#endif

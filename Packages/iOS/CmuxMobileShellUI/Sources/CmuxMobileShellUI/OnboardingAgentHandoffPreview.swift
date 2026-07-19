#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct OnboardingAgentHandoffPreview: View {
    let onRespond: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var answer: OnboardingDemoAnswer?

    var body: some View {
        VStack(spacing: 16) {
            OnboardingAgentQuestionCard()

            if let answer {
                OnboardingAgentAnswerReceipt(answer: answer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                OnboardingAgentAnswerChoices(onChoose: send)
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

    private func send(_ answer: OnboardingDemoAnswer) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
            self.answer = answer
        }
        onRespond()
    }
}

private enum OnboardingDemoAnswer: Equatable {
    case currentPR
    case followUpPR

    var title: String {
        switch self {
        case .currentPR:
            L10n.string(
                "mobile.onboarding.handoff.replyAlternative",
                defaultValue: "Fix it in this PR"
            )
        case .followUpPR:
            L10n.string(
                "mobile.onboarding.handoff.reply",
                defaultValue: "Open a follow-up PR"
            )
        }
    }
}

private struct OnboardingAgentQuestionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.indigo.gradient)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "desktopcomputer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string(
                        "mobile.onboarding.handoff.agent",
                        defaultValue: "Question from your Mac"
                    ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                    Text(L10n.string(
                        "mobile.onboarding.handoff.workspace",
                        defaultValue: "MacBook Pro · Fix reconnect test"
                    ))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                }
            }

            Text(L10n.string(
                "mobile.onboarding.handoff.question",
                defaultValue: "Where should I put this fix?"
            ))
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct OnboardingAgentAnswerChoices: View {
    let onChoose: (OnboardingDemoAnswer) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                alternativeButton
                primaryButton
            }
            VStack(spacing: 10) {
                primaryButton
                alternativeButton
            }
        }
    }

    private var alternativeButton: some View {
        Button {
            onChoose(.currentPR)
        } label: {
            Text(OnboardingDemoAnswer.currentPR.title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(.white)
        .accessibilityHint(replyHint)
        .accessibilityIdentifier("MobileOnboardingDemoReplyAlternativeButton")
    }

    private var primaryButton: some View {
        Button {
            onChoose(.followUpPR)
        } label: {
            Text(OnboardingDemoAnswer.followUpPR.title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint(replyHint)
        .accessibilityIdentifier("MobileOnboardingDemoReplyButton")
    }

    private var replyHint: String {
        L10n.string(
            "mobile.onboarding.handoff.replyHint",
            defaultValue: "Sends this answer in the interactive preview"
        )
    }
}

private struct OnboardingAgentAnswerReceipt: View {
    let answer: OnboardingDemoAnswer

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Text(answer.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor, in: Capsule())

            Label(
                L10n.string(
                    "mobile.onboarding.handoff.sent",
                    defaultValue: "Answer sent from iPhone"
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)

            Text(L10n.string(
                "mobile.onboarding.handoff.continuing",
                defaultValue: "Agent continuing on your Mac"
            ))
            .font(.caption)
            .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileOnboardingDemoReplySent")
    }
}
#endif

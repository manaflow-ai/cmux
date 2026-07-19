#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A decorative push-notification and reply vignette for onboarding.
struct OnboardingNotificationMockView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var animationStart = Date.now

    private enum Phase: Equatable {
        case banner
        case reply
        case fading
        case gap

        var showsBanner: Bool {
            self == .banner || self == .reply
        }

        var showsReply: Bool {
            self == .reply
        }

        var animation: Animation {
            switch self {
            case .banner, .reply:
                .spring(response: 0.5, dampingFraction: 0.8)
            case .fading:
                .easeOut(duration: 0.3)
            case .gap:
                .linear(duration: 0.01)
            }
        }
    }

    var body: some View {
        Group {
            if accessibilityReduceMotion {
                vignette(showsBanner: true, showsReply: true)
            } else {
                TimelineView(.periodic(from: animationStart, by: 0.05)) { context in
                    let phase = phase(at: context.date)
                    vignette(showsBanner: phase.showsBanner, showsReply: phase.showsReply)
                        .animation(phase.animation, value: phase)
                }
            }
        }
        .frame(maxWidth: 320)
        .accessibilityHidden(true)
    }

    private func vignette(showsBanner: Bool, showsReply: Bool) -> some View {
        VStack(spacing: 14) {
            banner
                .offset(y: showsBanner ? 0 : -40)
                .opacity(showsBanner ? 1 : 0)

            replyChip
                .scaleEffect(showsReply ? 1 : 0.85)
                .opacity(showsReply ? 1 : 0)
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.055, green: 0.065, blue: 0.09))
                Image("CmuxLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(
                    "mobile.onboarding.mock.notificationTitle",
                    defaultValue: "claude needs your input"
                ))
                .font(.footnote.bold())
                .lineLimit(2)
                Text(L10n.string(
                    "mobile.onboarding.mock.notificationBody",
                    defaultValue: "Run 24 tests and deploy the preview?"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            Spacer(minLength: 4)

            Text(L10n.string("mobile.workspace.preview.justNow", defaultValue: "now"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var replyChip: some View {
        HStack(spacing: 8) {
            Text(L10n.string(
                "mobile.onboarding.mock.reply",
                defaultValue: "Yes — go ahead"
            ))
            .font(.footnote.weight(.semibold))
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .mobileGlassPill()
    }

    private func phase(at date: Date) -> Phase {
        let elapsed = max(0, date.timeIntervalSince(animationStart))
            .truncatingRemainder(dividingBy: 4.5)
        switch elapsed {
        case ..<1.2:
            return .banner
        case ..<3.4:
            return .reply
        case ..<3.7:
            return .fading
        default:
            return .gap
        }
    }
}
#endif

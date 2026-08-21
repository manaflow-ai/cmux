#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// An in-app vignette of a cmux push notification and its inline reply,
/// matching the real payload shape (title = agent, subtitle = workspace,
/// body = status) and the real reply action strings. Loops through banner →
/// typing → sent; Reduce Motion shows the completed reply statically.
struct OnboardingPushPreview: View {
    private enum Phase {
        case banner
        case replying
        case sent
    }

    @State private var phase: Phase = .banner
    @State private var typedCharacterCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let replyText = "Run it"
    private let clock = ContinuousClock()

    var body: some View {
        VStack(spacing: 14) {
            notificationBanner
            // Always laid out so the vignette's frame stays stable while the
            // loop animates; only visibility changes.
            replyField
                .opacity(showsReplyField ? 1 : 0)
                .offset(y: showsReplyField ? 0 : 6)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "mobile.onboarding.push.previewAccessibility",
            defaultValue: "Example cmux notification: the agent claude asks for approval, and you reply from the notification without opening the app."
        ))
        .accessibilityIdentifier("MobileOnboardingPushPreview")
        .task {
            guard !reduceMotion else {
                typedCharacterCount = Self.replyText.count
                phase = .replying
                return
            }
            await runLoop()
        }
    }

    private var showsReplyField: Bool {
        phase != .banner
    }

    private var notificationBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "claude")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(L10n.string(
                        "mobile.onboarding.push.previewTime",
                        defaultValue: "now"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(verbatim: "issue-4821")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L10n.string(
                    "mobile.onboarding.push.previewBody",
                    defaultValue: "Approval needed"
                ))
                .font(.footnote)
                .foregroundStyle(.primary)
            }
        }
        .padding(14)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }

    private var appIcon: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.black.gradient)
            .frame(width: 38, height: 38)
            .overlay {
                Text(verbatim: ">_")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
    }

    private var replyField: some View {
        HStack(spacing: 10) {
            Group {
                if typedCharacterCount > 0 {
                    Text(String(Self.replyText.prefix(typedCharacterCount)))
                        .foregroundStyle(.primary)
                } else {
                    // Reuses the real reply action's placeholder from this
                    // package's catalog, so the vignette matches the actual
                    // notification text field.
                    Text(String(
                        localized: "mobile.push.reply.placeholder",
                        defaultValue: "Message the agent…",
                        bundle: .module
                    ))
                    .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if phase == .sent {
                    Label(
                        L10n.string(
                            "mobile.onboarding.push.previewSent",
                            defaultValue: "Sent to your Mac"
                        ),
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(
                            typedCharacterCount > 0 ? Color.accentColor : Color.secondary.opacity(0.4)
                        )
                }
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            .thinMaterial,
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            setPhase(.banner, typedCharacters: 0)
            guard await pause(for: .seconds(1.4)) else { return }

            setPhase(.replying, typedCharacters: 0)
            guard await pause(for: .seconds(0.6)) else { return }
            for count in 1...Self.replyText.count {
                typedCharacterCount = count
                guard await pause(for: .milliseconds(110)) else { return }
            }
            guard await pause(for: .seconds(0.4)) else { return }

            setPhase(.sent, typedCharacters: Self.replyText.count)
            guard await pause(for: .seconds(1.8)) else { return }
        }
    }

    private func setPhase(_ newPhase: Phase, typedCharacters: Int) {
        withAnimation(.smooth(duration: 0.3)) {
            phase = newPhase
            typedCharacterCount = typedCharacters
        }
    }

    private func pause(for duration: Duration) async -> Bool {
        do {
            try await clock.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }
}
#endif

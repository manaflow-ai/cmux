#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A replica of the real lock-screen moment: an expanded cmux notification
/// (Time Sensitive header, app icon, agent title, completion subtitle, body)
/// with the inline-reply field open beneath it, exactly as iOS renders it
/// during a reply. The vignette loops a typed reply; Reduce Motion shows the
/// completed reply statically. Always rendered dark, like Notification Center.
struct OnboardingPushPreview: View {
    private enum Phase {
        case idle
        case typing
        case sent
    }

    @State private var phase: Phase = .idle
    @State private var typedCharacterCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let replyText = "Merge it"
    private let clock = ContinuousClock()

    var body: some View {
        VStack(spacing: 10) {
            notificationCard
            replyField
        }
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string(
            "mobile.onboarding.push.previewAccessibility",
            defaultValue: "Example cmux notification: the agent claude finished and asks about merging, and you reply from the notification without opening the app."
        ))
        .accessibilityIdentifier("MobileOnboardingPushPreview")
        .task {
            guard !reduceMotion else {
                typedCharacterCount = Self.replyText.count
                phase = .typing
                return
            }
            await runLoop()
        }
    }

    private var notificationCard: some View {
        HStack(alignment: .center, spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.string(
                        "mobile.onboarding.push.previewTimeSensitive",
                        defaultValue: "TIME SENSITIVE"
                    ))
                    .font(.caption2.weight(.medium))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(L10n.string(
                        "mobile.onboarding.push.previewTime",
                        defaultValue: "now"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(verbatim: "claude")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(L10n.string(
                    "mobile.onboarding.push.previewSubtitle",
                    defaultValue: "Completed in issue-4821"
                ))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                Text(L10n.string(
                    "mobile.onboarding.push.previewBody",
                    defaultValue: "Tests are green and the PR is ready for review. Want me to merge it?"
                ))
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private var appIcon: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.white)
            .frame(width: 40, height: 40)
            .overlay {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 19, weight: .black))
                    .foregroundStyle(Color.accentColor)
            }
    }

    private var replyField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 1) {
                if typedCharacterCount > 0 {
                    Text(String(Self.replyText.prefix(typedCharacterCount)))
                        .foregroundStyle(.primary)
                }
                if phase != .sent {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 20)
                        .accessibilityHidden(true)
                }
                if typedCharacterCount == 0 {
                    // Reuses the real reply action's strings from this
                    // package's catalog, so the vignette matches the actual
                    // notification text field.
                    Text(String(
                        localized: "mobile.push.reply.placeholder",
                        defaultValue: "Message the agent…",
                        bundle: .module
                    ))
                    .foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(
                localized: "mobile.push.reply.send",
                defaultValue: "Send",
                bundle: .module
            ))
            .font(.body)
            .foregroundStyle(
                typedCharacterCount > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private func runLoop() async {
        while !Task.isCancelled {
            setPhase(.idle, typedCharacters: 0)
            guard await pause(for: .seconds(1.4)) else { return }

            setPhase(.typing, typedCharacters: 0)
            guard await pause(for: .seconds(0.5)) else { return }
            for count in 1...Self.replyText.count {
                typedCharacterCount = count
                guard await pause(for: .milliseconds(110)) else { return }
            }
            guard await pause(for: .seconds(0.5)) else { return }

            setPhase(.sent, typedCharacters: Self.replyText.count)
            guard await pause(for: .seconds(1.6)) else { return }
        }
    }

    private func setPhase(_ newPhase: Phase, typedCharacters: Int) {
        withAnimation(.smooth(duration: 0.25)) {
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

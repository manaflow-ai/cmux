#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Introduces the task composer as an agent-launch surface rather than a settings form.
struct TaskComposerHero: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.58)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .frame(width: 48, height: 48)
            .padding(.top, 6)
            .shadow(color: Color.accentColor.opacity(0.22), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 5) {
                Text(
                    L10n.string(
                        "mobile.taskComposer.hero.title",
                        defaultValue: "Start an agent"
                    )
                )
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

                Text(
                    L10n.string(
                        "mobile.taskComposer.hero.subtitle",
                        defaultValue: "Describe the outcome. cmux opens a workspace and puts your agent to work."
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileTaskComposerHero")
    }
}
#endif

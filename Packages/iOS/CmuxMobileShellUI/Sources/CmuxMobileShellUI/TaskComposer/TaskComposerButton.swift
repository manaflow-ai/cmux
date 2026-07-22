#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct TaskComposerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityHidden(true)
                Text(
                    L10n.string(
                        "mobile.taskComposer.button.title",
                        defaultValue: "New task"
                    )
                )
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 17)
            .frame(minHeight: 52)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .mobileGlassPill()
        .accessibilityLabel(L10n.string("mobile.taskComposer.button.accessibilityLabel", defaultValue: "New Task"))
        .accessibilityHint(
            L10n.string("mobile.taskComposer.button.accessibilityHint", defaultValue: "Opens the task composer.")
        )
        .accessibilityIdentifier("MobileTaskComposerButton")
    }
}
#endif

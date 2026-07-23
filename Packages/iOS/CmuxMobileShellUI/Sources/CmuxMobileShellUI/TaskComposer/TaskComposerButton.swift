#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct TaskComposerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
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

#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct TaskComposerButton: View {
    let action: () -> Void
    var diameter: CGFloat = 52

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: diameter, height: diameter)
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

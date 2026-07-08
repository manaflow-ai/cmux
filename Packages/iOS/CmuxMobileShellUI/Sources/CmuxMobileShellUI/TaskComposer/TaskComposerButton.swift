#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct TaskComposerButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .mobileGlassCircle()
        .accessibilityLabel(L10n.string("mobile.taskComposer.button.accessibilityLabel", defaultValue: "New Task"))
        .accessibilityIdentifier("MobileTaskComposerButton")
    }
}
#endif

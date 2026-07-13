#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The composer's persistent primary action. Keeping it outside the virtualized
/// form makes the visible action a stable accessibility element while the form
/// scrolls on compact and regular-width layouts.
struct TaskComposerPrimaryAction: View {
    let isSubmitting: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: action) {
                Group {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text(L10n.string("mobile.taskComposer.create", defaultValue: "Create"))
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSubmitting || !isEnabled)
            .accessibilityLabel(
                isSubmitting
                    ? L10n.string("mobile.taskComposer.creating", defaultValue: "Creating Task")
                    : L10n.string("mobile.taskComposer.create", defaultValue: "Create")
            )
            .accessibilityHint(TaskComposerSheet.createAccessibilityHint)
            .accessibilityIdentifier("MobileTaskComposerCreateButton")
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}
#endif

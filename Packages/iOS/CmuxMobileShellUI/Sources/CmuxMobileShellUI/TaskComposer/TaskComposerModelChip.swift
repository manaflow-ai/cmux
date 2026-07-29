#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Compact model menu displayed beside the composer agent menu.
struct TaskComposerModelChip: View {
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let isDisabled: Bool
    let selectModel: (String?) -> Void

    var body: some View {
        Menu {
            TaskComposerModelMenuContent(
                models: models,
                selectedModelID: selectedModelID,
                selectModel: selectModel
            )
        } label: {
            Text(verbatim: selectedModelName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                // Adopt a longer model name's width immediately; animating the
                // capsule clips the label against the stale width.
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                }
                // Keep the compact 28pt capsule while honoring the composer's
                // 44pt activation-target contract.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .taskComposerModelAccessibility(valueName: selectedModelName)
        .accessibilityIdentifier("MobileTaskComposerModelChip")
    }

    private var selectedModelName: String {
        models.displayName(forSelected: selectedModelID)
    }
}
#endif

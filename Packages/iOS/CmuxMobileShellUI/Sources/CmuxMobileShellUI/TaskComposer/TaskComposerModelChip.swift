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
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.model", defaultValue: "Model"))
        .accessibilityValue(selectedModelName)
        .accessibilityHint(L10n.string(
            "mobile.taskComposer.model.accessibilityHint",
            defaultValue: "Chooses the model this agent runs with."
        ))
        .accessibilityIdentifier("MobileTaskComposerModelChip")
    }

    private var selectedModelName: String {
        models.first { $0.id == selectedModelID }?.displayName
            ?? L10n.string("mobile.taskComposer.model.default", defaultValue: "Default")
    }
}
#endif

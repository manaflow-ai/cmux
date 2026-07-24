#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Dedicated model menu shown below the composer agent row.
struct TaskComposerModelRow: View {
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
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.1), in: Circle())
                    .accessibilityHidden(true)

                Text(L10n.string("mobile.taskComposer.model", defaultValue: "Model"))
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)

                Spacer(minLength: 8)

                Text(verbatim: selectedModelName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.model", defaultValue: "Model"))
        .accessibilityValue(selectedModelName)
        .accessibilityHint(L10n.string(
            "mobile.taskComposer.model.accessibilityHint",
            defaultValue: "Chooses the model this agent runs with."
        ))
        .accessibilityIdentifier("MobileTaskComposerModelRow")
    }

    private var selectedModelName: String {
        models.first { $0.id == selectedModelID }?.displayName
            ?? L10n.string("mobile.taskComposer.model.default", defaultValue: "Default")
    }
}
#endif

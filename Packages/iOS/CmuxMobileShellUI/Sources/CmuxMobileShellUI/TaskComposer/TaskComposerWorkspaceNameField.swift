#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct TaskComposerWorkspaceNameField: View {
    @Binding var workspaceName: String
    let isDisabled: Bool
    let endEditing: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(
                L10n.string(
                    "mobile.taskComposer.workspaceName.optional",
                    defaultValue: "Workspace name (optional)"
                )
            )
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)

            TextField(
                L10n.string(
                    "mobile.taskComposer.workspaceName.generatedPlaceholder",
                    defaultValue: "Generated from prompt"
                ),
                text: $workspaceName
            )
            .textFieldStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .focused($isFocused)
            .disabled(isDisabled)
            .accessibilityLabel(
                L10n.string(
                    "mobile.taskComposer.workspaceName.optional",
                    defaultValue: "Workspace name (optional)"
                )
            )
            .accessibilityIdentifier("MobileTaskComposerWorkspaceName")
            .taskComposerEditingCompletion(
                isFocused: isFocused,
                endEditing: endEditing
            )
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
#endif

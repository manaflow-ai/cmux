#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct TaskComposerWorkspaceNameField: View {
    @Binding var workspaceName: String
    let isDisabled: Bool
    let endEditing: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 28, height: 28)
                .background(Color.indigo.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("mobile.taskComposer.workspaceName", defaultValue: "Workspace name"))
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
                        "mobile.taskComposer.workspaceName",
                        defaultValue: "Workspace name"
                    )
                )
                .accessibilityIdentifier("MobileTaskComposerWorkspaceName")
                .onSubmit(endEditing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: isFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                endEditing()
            }
        }
    }
}
#endif

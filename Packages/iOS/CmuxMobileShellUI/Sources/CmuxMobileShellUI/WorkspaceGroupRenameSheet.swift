#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A small sheet that renames a workspace group from the mobile workspace list.
struct WorkspaceGroupRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let onSave: (String) -> Void
    @State private var name: String

    init(currentName: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: currentName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    L10n.string("mobile.workspaceGroup.rename.placeholder", defaultValue: "Group name"),
                    text: $name
                )
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(save)
                .accessibilityIdentifier("WorkspaceGroupRenameField")
            }
            .navigationTitle(L10n.string("mobile.workspaceGroup.rename.title", defaultValue: "Rename Group"))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("WorkspaceGroupRenameCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("WorkspaceGroupRenameSaveButton")
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
#endif

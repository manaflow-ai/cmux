#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A small sheet that renames a workspace from the mobile workspace list.
///
/// Seeds its text field with the current name and hands the trimmed result back
/// through `onSave`; the caller forwards it to the Mac. Whitespace-only names are
/// rejected (Save is disabled).
struct WorkspaceRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let onSave: (String) -> Void
    @State private var name: String

    /// Creates the rename sheet.
    /// - Parameters:
    ///   - currentName: The workspace's current name, used to seed the field.
    ///   - onSave: Called with the new trimmed name when the user taps Save.
    init(currentName: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _name = State(initialValue: currentName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(
                    L10n.string("mobile.workspace.rename.placeholder", defaultValue: "Workspace name"),
                    text: $name
                )
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(save)
                .accessibilityIdentifier("WorkspaceRenameField")
            }
            .navigationTitle(L10n.string("mobile.workspace.rename.title", defaultValue: "Rename Workspace"))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("WorkspaceRenameCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("WorkspaceRenameSaveButton")
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

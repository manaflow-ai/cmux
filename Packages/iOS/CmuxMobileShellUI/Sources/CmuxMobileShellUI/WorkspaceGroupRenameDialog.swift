#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Compact group-rename alert shared by SwiftUI and UIKit-backed list actions.
extension View {
    func workspaceGroupRenameDialog(
        isPresented: Binding<Bool>,
        text: Binding<String>,
        onSave: @escaping (String) -> Void
    ) -> some View {
        alert(
            L10n.string("mobile.workspaceGroup.rename.title", defaultValue: "Rename Group"),
            isPresented: isPresented
        ) {
            TextField(
                L10n.string("mobile.workspaceGroup.rename.placeholder", defaultValue: "Group name"),
                text: text
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("WorkspaceGroupRenameField")
            Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                let trimmed = text.wrappedValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty else { return }
                onSave(trimmed)
                isPresented.wrappedValue = false
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("WorkspaceGroupRenameSaveButton")
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                isPresented.wrappedValue = false
            }
            .accessibilityIdentifier("WorkspaceGroupRenameCancelButton")
        }
    }
}
#endif

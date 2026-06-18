import CmuxMobileSupport
import SwiftUI

/// Rename-workspace dialog (an alert with an inline text field) shared by the
/// workspace detail view's terminal-icon menu across the terminal / chat /
/// browser panes. Reuses the same strings as the workspace list's rename sheet so
/// both entrypoints read identically.
extension View {
    func workspaceRenameDialog(
        isPresented: Binding<Bool>,
        text: Binding<String>,
        onSave: @escaping () -> Void
    ) -> some View {
        alert(
            L10n.string("mobile.workspace.rename.title", defaultValue: "Rename Workspace"),
            isPresented: isPresented
        ) {
            TextField(
                L10n.string("mobile.workspace.rename.placeholder", defaultValue: "Workspace name"),
                text: text
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("WorkspaceRenameField")
            Button(L10n.string("mobile.common.save", defaultValue: "Save"), action: onSave)
                .accessibilityIdentifier("WorkspaceRenameSaveButton")
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                isPresented.wrappedValue = false
            }
            .accessibilityIdentifier("WorkspaceRenameCancelButton")
        }
    }
}

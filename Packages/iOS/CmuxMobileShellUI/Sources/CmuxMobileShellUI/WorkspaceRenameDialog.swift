import CmuxMobileSupport
import SwiftUI

/// Rename-workspace dialog (an alert with an inline text field) shared by the
/// workspace detail view's title menu across the terminal / chat /
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
                // Disable Save for whitespace-only names (matching the list's
                // rename sheet) so it never dismisses on empty input with no
                // rename and no feedback. The alert content re-evaluates as the
                // bound text changes, so this tracks the field live.
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("WorkspaceRenameSaveButton")
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                isPresented.wrappedValue = false
            }
            .accessibilityIdentifier("WorkspaceRenameCancelButton")
        }
    }
}

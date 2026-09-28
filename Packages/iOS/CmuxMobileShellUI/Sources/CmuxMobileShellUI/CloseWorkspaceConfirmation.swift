import CmuxMobileSupport
import SwiftUI

/// Destructive close-workspace confirmation dialog shared by the workspace
/// detail view's top-bar menu. Reuses the same strings as the workspace list's
/// swipe/context close so both entrypoints read identically.
extension View {
    func closeWorkspaceConfirmation(
        isPresented: Binding<Bool>,
        confirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            L10n.string("mobile.workspace.delete.confirmTitle", defaultValue: "Delete Workspace?"),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(
                L10n.string("mobile.workspace.delete.confirmAction", defaultValue: "Delete"),
                role: .destructive,
                action: confirm
            )
            .accessibilityIdentifier("MobileCloseWorkspaceConfirmButton")
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                isPresented.wrappedValue = false
            }
        } message: {
            Text(L10n.string("mobile.workspace.delete.confirmMessage", defaultValue: "This will close the workspace on your Mac."))
        }
    }
}

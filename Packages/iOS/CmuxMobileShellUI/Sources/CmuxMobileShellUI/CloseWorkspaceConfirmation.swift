import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Destructive close-workspace confirmation dialog shared by the workspace
/// detail view's top-bar menu. Renders the same
/// ``MobileWorkspaceCloseConfirmation`` the workspace list's swipe and context
/// close resolve, so every entrypoint reads identically.
extension View {
    func closeWorkspaceConfirmation(
        _ confirmation: MobileWorkspaceCloseConfirmation,
        isPresented: Binding<Bool>,
        confirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            confirmation.title,
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(confirmation.actionTitle, role: .destructive, action: confirm)
                .accessibilityIdentifier("MobileCloseWorkspaceConfirmButton")
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                isPresented.wrappedValue = false
            }
        } message: {
            Text(confirmation.message)
        }
    }
}

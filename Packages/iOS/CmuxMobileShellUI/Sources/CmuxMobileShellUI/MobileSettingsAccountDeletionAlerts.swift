#if os(iOS)
import SwiftUI

private struct MobileSettingsAccountDeletionAlerts: ViewModifier {
    @Binding var showingConfirmation: Bool
    @Binding var errorMessage: String?
    let deleteAccount: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                L10n.string("mobile.settings.deleteAccountConfirmationTitle", defaultValue: "Delete this account?"),
                isPresented: $showingConfirmation
            ) {
                Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
                Button(
                    L10n.string("mobile.settings.deleteAccount", defaultValue: "Delete Account"),
                    role: .destructive,
                    action: deleteAccount
                )
            } message: {
                Text(L10n.string(
                    "mobile.settings.deleteAccountConfirmationMessage",
                    defaultValue: "This permanently deletes your cmux account and signs this device out. This cannot be undone."
                ))
            }
            .alert(
                L10n.string("mobile.settings.deleteAccountFailedTitle", defaultValue: "Could Not Delete Account"),
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

extension View {
    func mobileSettingsAccountDeletionAlerts(
        showingConfirmation: Binding<Bool>,
        errorMessage: Binding<String?>,
        deleteAccount: @escaping () -> Void
    ) -> some View {
        modifier(MobileSettingsAccountDeletionAlerts(
            showingConfirmation: showingConfirmation,
            errorMessage: errorMessage,
            deleteAccount: deleteAccount
        ))
    }
}
#endif

#if os(iOS)
import CmuxMobileSupport
import SwiftUI

private struct MobileSettingsAccountDeletionAlerts: ViewModifier {
    @Binding var showingConfirmation: Bool
    @Binding var errorMessage: String?
    @Binding var acceptedMessage: String?
    let deleteAccount: () -> Void
    let acceptedAcknowledged: () -> Void

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
            .alert(
                L10n.string("mobile.settings.deleteAccountAcceptedTitle", defaultValue: "Deletion Request Started"),
                isPresented: Binding(get: { acceptedMessage != nil }, set: { if !$0 { acceptedMessage = nil } })
            ) {
                Button(
                    L10n.string("mobile.common.ok", defaultValue: "OK"),
                    role: .cancel,
                    action: acceptedAcknowledged
                )
            } message: {
                Text(acceptedMessage ?? "")
            }
    }
}

extension View {
    func mobileSettingsAccountDeletionAlerts(
        showingConfirmation: Binding<Bool>,
        errorMessage: Binding<String?>,
        acceptedMessage: Binding<String?>,
        deleteAccount: @escaping () -> Void,
        acceptedAcknowledged: @escaping () -> Void
    ) -> some View {
        modifier(MobileSettingsAccountDeletionAlerts(
            showingConfirmation: showingConfirmation,
            errorMessage: errorMessage,
            acceptedMessage: acceptedMessage,
            deleteAccount: deleteAccount,
            acceptedAcknowledged: acceptedAcknowledged
        ))
    }
}
#endif

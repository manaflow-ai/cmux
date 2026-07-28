#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI

struct MobileSettingsAccountSection: View {
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    let signOut: (() -> Void)?

    @State private var showingDeleteAccountConfirmation = false
    @State private var showingDeleteAccountFailure = false
    @State private var deleteAccountFailureKind = DeleteAccountFailureKind.generic
    @State private var deletingAccount = false
    @State private var deleteAccountTask: Task<Void, Never>?
    @State private var signOutAfterDeleteAccountFailureAcknowledgement = false

    var body: some View {
        Section {
            LabeledContent {
                Text(accountEmail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label(accountDisplayName, systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("MobileSettingsAccountRow")

            if let signOut {
                Button(role: .destructive) {
                    signOut()
                    dismiss()
                } label: {
                    Label(
                        L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
                .accessibilityIdentifier("MobileSettingsSignOut")
            }

            Button(role: .destructive) {
                showingDeleteAccountConfirmation = true
            } label: {
                Label(
                    deletingAccount
                        ? L10n.string("mobile.settings.deletingAccount", defaultValue: "Deleting Account...")
                        : L10n.string("mobile.settings.deleteAccount", defaultValue: "Delete Account"),
                    systemImage: deletingAccount ? "hourglass" : "trash"
                )
            }
            .disabled(deletingAccount)
            .accessibilityIdentifier("MobileSettingsDeleteAccount")
        } header: {
            Text(L10n.string("mobile.settings.account", defaultValue: "Account"))
        } footer: {
            Text(L10n.string(
                "mobile.settings.accountFooter",
                defaultValue: "This device must be signed in to the same cmux account as the computer you pair with."
            ))
        }
        .alert(
            L10n.string("mobile.settings.deleteAccountTitle", defaultValue: "Delete Account?"),
            isPresented: $showingDeleteAccountConfirmation
        ) {
            Button(L10n.string("mobile.settings.deleteAccountCancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(
                L10n.string("mobile.settings.deleteAccountConfirm", defaultValue: "Delete Account"),
                role: .destructive
            ) {
                deleteAccount()
            }
        } message: {
            Text(L10n.string(
                "mobile.settings.deleteAccountMessage",
                defaultValue: "This permanently deletes your cmux account and cmux data. You will be signed out on this device."
            ))
        }
        .alert(
            deleteAccountFailureKind.localizedTitle,
            isPresented: $showingDeleteAccountFailure
        ) {
            Button(L10n.string("mobile.settings.deleteAccountFailureOK", defaultValue: "OK"), role: .cancel) {
                acknowledgeDeleteAccountFailure()
            }
        } message: {
            Text(deleteAccountFailureKind.localizedMessage)
        }
    }

    private func deleteAccount() {
        guard !deletingAccount, deleteAccountTask == nil else { return }
        deletingAccount = true
        deleteAccountTask = Task {
            defer {
                deleteAccountTask = nil
                deletingAccount = false
            }
            do {
                let result = try await authManager.deleteAccount()
                switch result {
                case .completed:
                    await signOutDeletedAccount()
                    dismiss()
                case .completedWithIncompleteServerCleanup:
                    deleteAccountFailureKind = .serverCleanupIncomplete
                    signOutAfterDeleteAccountFailureAcknowledgement = deleteAccountFailureKind.signsOutAfterAcknowledgement
                    showingDeleteAccountFailure = true
                }
            } catch {
                deleteAccountFailureKind = DeleteAccountFailureKind(error: error)
                signOutAfterDeleteAccountFailureAcknowledgement = deleteAccountFailureKind.signsOutAfterAcknowledgement
                showingDeleteAccountFailure = true
            }
        }
    }

    private func acknowledgeDeleteAccountFailure() {
        guard signOutAfterDeleteAccountFailureAcknowledgement else { return }
        signOutAfterDeleteAccountFailureAcknowledgement = false
        Task {
            await signOutDeletedAccount()
            dismiss()
        }
    }

    private func signOutDeletedAccount() async {
        if let signOut {
            signOut()
        } else {
            await authManager.signOut()
        }
    }

    private var accountEmail: String {
        let email = authManager.currentUser?.primaryEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty { return email }
        return L10n.string("mobile.settings.notSignedIn", defaultValue: "Not signed in")
    }

    private var accountDisplayName: String {
        let name = authManager.currentUser?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return L10n.string("mobile.settings.account", defaultValue: "Account")
    }
}
#endif

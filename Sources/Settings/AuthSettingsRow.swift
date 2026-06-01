import SwiftUI

struct AuthSettingsRow: View {
    @ObservedObject var authManager: AuthManager

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 12)
            if authManager.isLoading || authManager.isRestoringSession {
                ProgressView().controlSize(.small)
                    .padding(.top, 2)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Button(action: buttonAction) {
                    Text(buttonTitle)
                }
                .controlSize(.small)
                .disabled(authManager.isLoading || authManager.isRestoringSession)
                if let signInErrorText {
                    Text(signInErrorText)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var titleText: String {
        if authManager.isAuthenticated {
            if let email = authManager.currentUser?.primaryEmail, !email.isEmpty {
                return email
            }
            return String(
                localized: "settings.account.signedIn.title",
                defaultValue: "Signed in"
            )
        }
        return String(
            localized: "settings.account.signedOut.title",
            defaultValue: "Not signed in"
        )
    }

    private var subtitleText: String? {
        if authManager.isAuthenticated {
            return authManager.currentUser?.displayName
        }
        return String(
            localized: "settings.account.signedOut.subtitle",
            defaultValue: "Sign in with your cmux account to enable sync across devices."
        )
    }

    private var signInErrorText: String? {
        guard !authManager.isAuthenticated else { return nil }
        return authManager.lastSignInError?.localizedMessage
    }

    private var buttonTitle: String {
        if authManager.isAuthenticated {
            return String(
                localized: "settings.account.signOut",
                defaultValue: "Sign Out"
            )
        }
        return String(
            localized: "settings.account.signIn",
            defaultValue: "Sign In…"
        )
    }

    private func buttonAction() {
        guard !authManager.isLoading && !authManager.isRestoringSession else { return }
        if authManager.isAuthenticated {
            Task { @MainActor in
                await authManager.signOut()
            }
        } else {
            authManager.beginSignIn()
        }
    }
}

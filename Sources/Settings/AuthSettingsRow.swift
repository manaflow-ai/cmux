import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct AuthSettingsRow: View {
    @ObservedObject var authManager: AuthManager

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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
            }
            Button(action: buttonAction) {
                Text(buttonTitle)
            }
            .controlSize(.small)
            .disabled(authManager.isLoading || authManager.isRestoringSession)
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
        if authManager.isAuthenticated {
            Task { @MainActor in
                await authManager.signOut()
            }
        } else {
            authManager.beginSignIn()
        }
    }
}

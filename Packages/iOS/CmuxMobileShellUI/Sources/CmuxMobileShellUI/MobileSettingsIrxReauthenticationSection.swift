#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// Explains an irx authentication rejection and confirms the sign-out needed
/// to start a fresh account session.
struct MobileSettingsIrxReauthenticationSection: View {
    let signOut: (() -> Void)?

    @State private var showingSignOutConfirmation = false

    var body: some View {
        Section {
            Label {
                Text(L10n.string(
                    "mobile.settings.iroh.reauth.message",
                    defaultValue: "Sign in again to reconnect this device."
                ))
            } icon: {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if signOut != nil {
                Button(
                    L10n.string(
                        "mobile.settings.iroh.reauth.action",
                        defaultValue: "Sign Out and Sign In Again"
                    )
                ) {
                    showingSignOutConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("MobileSettingsIrohReauthenticationAction")
            } else {
                Text(L10n.string(
                    "mobile.settings.iroh.reauth.fallback",
                    defaultValue: "Open the account section above and sign in again to reconnect."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.string(
                "mobile.settings.iroh.reauth.title",
                defaultValue: "Networking Needs Sign-In"
            ))
        }
        .accessibilityIdentifier("MobileSettingsIrohReauthentication")
        .confirmationDialog(
            L10n.string(
                "mobile.settings.iroh.reauth.title",
                defaultValue: "Networking Needs Sign-In"
            ),
            isPresented: $showingSignOutConfirmation,
            titleVisibility: .visible
        ) {
            if let signOut {
                Button(
                    L10n.string(
                        "mobile.settings.iroh.reauth.action",
                        defaultValue: "Sign Out and Sign In Again"
                    ),
                    role: .destructive,
                    action: signOut
                )
            }
            Button(
                L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {}
        } message: {
            Text(L10n.string(
                "mobile.settings.iroh.reauth.message",
                defaultValue: "Sign in again to reconnect this device."
            ))
        }
    }
}
#endif

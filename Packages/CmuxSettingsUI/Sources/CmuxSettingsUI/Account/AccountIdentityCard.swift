import CmuxSettings
import SwiftUI

/// Identity row rendered at the top of the Account section.
///
/// Mirrors the legacy in-app `AuthSettingsRow`: a primary email title
/// (13pt medium), a display-name subtitle (11pt secondary), an
/// optional inline `ProgressView` while auth is in flight, and a
/// trailing Sign In / Sign Out button. No avatar, no redaction —
/// matches the legacy layout exactly.
@MainActor
struct AccountIdentityCard: View {
    let flow: AccountFlow?

    init(flow: AccountFlow?) {
        self.flow = flow
    }

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
            if flow?.isWorkingOnAuth == true {
                ProgressView().controlSize(.small)
            }
            Button(action: buttonAction) {
                Text(buttonTitle)
            }
            .controlSize(.small)
            .disabled(flow?.isWorkingOnAuth == true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var titleText: String {
        if let identity = flow?.currentIdentity {
            if !identity.email.isEmpty {
                return identity.email
            }
            return String(localized: "settings.account.signedIn.title", defaultValue: "Signed in")
        }
        return String(localized: "settings.account.signedOut.title", defaultValue: "Not signed in")
    }

    private var subtitleText: String? {
        if let identity = flow?.currentIdentity {
            // Legacy AuthSettingsRow returns authManager.currentUser?.displayName
            // directly. Pass the raw value through (including empty strings) so
            // the row shape matches when displayName is set to "".
            return identity.displayName
        }
        return String(localized: "settings.account.signedOut.subtitle", defaultValue: "Sign in with your cmux account to enable sync across devices.")
    }

    private var buttonTitle: String {
        if flow?.currentIdentity != nil {
            return String(localized: "settings.account.signOut", defaultValue: "Sign Out")
        }
        return String(localized: "settings.account.signIn", defaultValue: "Sign In…")
    }

    private func buttonAction() {
        guard let flow else { return }
        if flow.currentIdentity != nil {
            Task { await flow.signOut() }
        } else {
            flow.startSignIn()
        }
    }
}

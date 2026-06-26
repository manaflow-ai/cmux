import CmuxFoundation
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                        .cmuxFont(size: 13, weight: .medium)
                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .cmuxFont(size: 11)
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
            if showSignInRecovery {
                signInRecovery
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The Safari-backed system sign-in window can open and never redirect back
    /// to the app (issue #6015). While signed out, offer to finish sign-in in
    /// the user's default browser whenever the attempt is slow or has failed
    /// outright — so a hang surfaces an actionable recovery path instead of an
    /// indefinite spinner or a silent return to "Not signed in".
    private var showSignInRecovery: Bool {
        guard flow?.currentIdentity == nil else { return false }
        return flow?.signInIsSlow == true || signInErrorMessage != nil
    }

    /// The display-safe failure for the last sign-in attempt. Reached only
    /// through ``showSignInRecovery`` (which already gates on
    /// `currentIdentity == nil`), and `HostAccountFlow.signInErrorMessage`
    /// itself returns `nil` while signed in — so no extra guard is needed.
    private var signInErrorMessage: String? {
        flow?.signInErrorMessage
    }

    private var signInRecovery: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(signInRecoveryMessage)
                .cmuxFont(size: 11)
                .foregroundColor(signInErrorMessage == nil ? .secondary : .orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                flow?.openSignInInDefaultBrowser()
            } label: {
                Text(String(
                    localized: "settings.account.signIn.openInBrowser",
                    defaultValue: "Open in Browser"
                ))
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// The failure message when the last attempt failed, otherwise the
    /// slow-sign-in hint while an attempt is still in flight.
    private var signInRecoveryMessage: String {
        if let signInErrorMessage {
            return signInErrorMessage
        }
        return String(
            localized: "settings.account.signIn.slowHint",
            defaultValue: "The system sign-in window may stop responding. If nothing happens, open sign-in in your default browser instead."
        )
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

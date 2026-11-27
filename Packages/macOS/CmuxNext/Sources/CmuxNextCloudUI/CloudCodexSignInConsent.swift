public import CmuxNextDesign

/// The one-time consent before cmux first uses this Mac's own Codex sign-in for a Cloud machine the
/// person owns (``CloudCodexSignInConsentSetting``). Only the person's click answers it; the App keeps
/// the answer. Keys live in Resources/CloudCredentialRecovery.xcstrings with every app locale; the
/// buttons are the Claude consent's.
public struct CloudCodexSignInConsent {
    public init() {}

    public static let identifier = "cmux.dialog.cloud.codexSignInConsent"
    /// The id of the button that says yes.
    public static let accept = CloudLoginCopyConsent.accept

    public static var spec: CmuxDialogSpec {
        CmuxDialogSpec(
            title: String(localized: "cloud.codexSignInConsent.title", defaultValue: "Use my Codex login on my own Cloud machines?", table: "CloudCredentialRecovery", bundle: .module),
            lines: [String(localized: "cloud.codexSignInConsent.body", defaultValue: "cmux gives Cloud machines you own short-lived access from the Codex sign-in on this Mac. This Mac keeps the refresh token, so you stay signed in here, and cmux never stores it.", table: "CloudCredentialRecovery", bundle: .module),
                    String(localized: "cloud.codexSignInConsent.settings", defaultValue: "You can turn this off in Settings > Machines.", table: "CloudCredentialRecovery", bundle: .module)],
            buttons: [.cancel(String(localized: "cloud.loginCopyConsent.decline", defaultValue: "Don't Use", table: "CloudCredentialRecovery", bundle: .module)),
                      CmuxDialogButton(id: accept, title: String(localized: "cloud.loginCopyConsent.accept", defaultValue: "Use My Login", table: "CloudCredentialRecovery", bundle: .module), role: .default)],
            identifier: identifier)
    }
}

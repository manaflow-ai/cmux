public import CmuxNextDesign

/// The one-time consent before a Release build's first copy of the person's Claude login to their
/// own Cloud machines (Leo, 2026-11-02: "a clear one-time prompt: 'use my Claude login on my own
/// Cloud machines'"). The App presents ``spec`` and keeps the answer (`CloudLoginCopyConsentSetting`).
/// Keys live in Resources/CloudCredentialRecovery.xcstrings with every app locale.
public struct CloudLoginCopyConsent {
    public init() {}

    public static let identifier = "cmux.dialog.cloud.loginCopyConsent"
    /// The id of the button that says yes.
    public static let accept = "use"

    public static var spec: CmuxDialogSpec {
        CmuxDialogSpec(
            title: String(localized: "cloud.loginCopyConsent.title", defaultValue: "Use my Claude login on my own Cloud machines?", table: "CloudCredentialRecovery", bundle: .module),
            lines: [String(localized: "cloud.loginCopyConsent.body", defaultValue: "cmux copies your own Claude login from this Mac to Cloud machines you own, so their chats start signed in. It never goes to team or shared machines, and cmux never stores it.", table: "CloudCredentialRecovery", bundle: .module),
                    String(localized: "cloud.loginCopyConsent.settings", defaultValue: "You can turn this off in Settings > Machines. Without it, each machine offers Sign in to Claude.", table: "CloudCredentialRecovery", bundle: .module)],
            buttons: [.cancel(String(localized: "cloud.loginCopyConsent.decline", defaultValue: "Don't Use", table: "CloudCredentialRecovery", bundle: .module)),
                      CmuxDialogButton(id: accept, title: String(localized: "cloud.loginCopyConsent.accept", defaultValue: "Use My Login", table: "CloudCredentialRecovery", bundle: .module), role: .default)],
            identifier: identifier)
    }
}

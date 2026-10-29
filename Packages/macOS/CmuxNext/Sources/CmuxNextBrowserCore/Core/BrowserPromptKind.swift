public import Foundation

/// A capability a page asked for.
public nonisolated enum BrowserPermissionKind: Hashable, Sendable {
    case camera
    case microphone
    case cameraAndMicrophone
    /// A second download without a fresh user gesture
    /// (`AutomaticDownloadPolicy`): Allow or Block, remembered for the site.
    case automaticDownloads
    /// The device's location (Geolocation API): Block or Allow, remembered
    /// for the site.
    case location
    /// Web notifications (WebKit tabs): Block or Allow, remembered for the site.
    case notifications
}

/// What a prompt asks the user.
public nonisolated enum BrowserPromptKind: Hashable, Sendable {
    case permission(BrowserPermissionKind)
    case alert(message: String)
    case confirm(message: String)
    case textInput(message: String, defaultText: String?)
    /// HTTP authentication (Basic, Digest, NTLM): a user name and password
    /// for `host` (`realm` is the server's text, when it sends one).
    case credentials(host: String, realm: String?)
    /// A link to another app (`BrowserExternalApps`): open `scheme` links in
    /// the app named `app`? Answered `.allowOnce` (Open), `.allow` (Open,
    /// always for the site) or `.cancel`.
    case openExternalApp(app: String, scheme: String)
    /// Chromium's password manager asks to save (or, with `update`, to
    /// replace) the sign-in a person submitted (fork API 20). Answered
    /// `.accept` (Save / Update), `.deny` (never for the site) or `.cancel`
    /// (Not Now). The password itself never leaves Chromium.
    case savePassword(username: String, update: Bool)
    /// Email verification AutoFill (plans/cmux-next/email-verification-autofill/DESIGN.md):
    /// the code or link of a verification email from the page's own site, shown in native
    /// chrome the page cannot read. Answered `.accept` (Fill Code), `.allowOnce` (Open Link)
    /// or `.cancel` (Not Now). Never answered for an agent, never submits the form.
    case verificationOffer(VerificationOffer)
    /// The page's beforeunload asks before it unloads (Chrome's "Leave
    /// site?", "Reload site?" with `isReload`). Answered `.accept` (Leave or
    /// Reload) or `.cancel` (Cancel: the page stays). Never answered for an agent.
    case beforeUnload(isReload: Bool)

    /// A beforeunload question (`beforeUnload`).
    public var isBeforeUnload: Bool {
        if case .beforeUnload = self { true } else { false }
    }
}

/// The user's answer to a prompt.
public nonisolated enum BrowserPromptResponse: Hashable, Sendable {
    /// Permission: "Allow while visiting the site" (remembered for the origin).
    case allow
    /// Permission: "Allow this time" (this page load only, not remembered).
    case allowOnce
    /// Permission: "Never allow" (remembered as blocked).
    case deny
    /// Alert or confirm accepted.
    case accept
    /// Confirm or text input cancelled.
    case cancel
    case text(String)
    /// Credentials prompt submitted.
    /// `remember`: the user checked "Remember password".
    case credentials(user: String, password: String, remember: Bool = false)
}

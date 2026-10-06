public import Foundation

/// A capability a page asked for.
public nonisolated enum BrowserPermissionKind: Hashable, Sendable {
    case camera
    case microphone
    case cameraAndMicrophone
    /// A second download without a fresh user gesture
    /// (`AutomaticDownloadPolicy`): Allow or Block, remembered for the site.
    case automaticDownloads
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
    case credentials(user: String, password: String)
}

public import Foundation

/// cmux's own account as the Accounts screen shows it: who is signed in,
/// and where a sign-in in progress stands. The App reads it from Cloud auth.
public struct CmuxAccountState: Equatable, Sendable {
    public var signedIn: Bool
    /// A masked account label (`c…@o…`), never the full email.
    public var label: String?
    /// A sign-in is in progress (its popup or browser page is open).
    public var signingIn: Bool
    /// The sign-in waits in the default browser (it opened there, or the
    /// popup has been open a while): the screen offers to open it again.
    public var waitingForBrowser: Bool
    /// The last sign-in failed. The row says so in its own words: Cloud
    /// auth's reasons are not in this app's catalogs, and their diagnostic
    /// details stay in the log.
    public var failed: Bool
    /// A dev build's Cloud backend, as the row's note shows it (`CloudRuntimeSelection.developerBackendLabel`):
    /// which backend this build talks to, and whether a launch or the tag's `backend.json` chose it. Nil in
    /// release and RC builds, which never show it.
    public var backend: String?

    public init(signedIn: Bool, label: String? = nil, signingIn: Bool = false, waitingForBrowser: Bool = false, failed: Bool = false,
                backend: String? = nil) {
        self.backend = backend
        self.signedIn = signedIn
        self.label = label
        self.signingIn = signingIn
        self.waitingForBrowser = waitingForBrowser
        self.failed = failed
    }

    public static let signedOut = CmuxAccountState(signedIn: false)

    /// `name@example.com` as `n…@e…`, the way provider accounts show.
    public static func mask(_ email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        let name = email[..<at], domain = email[email.index(after: at)...]
        guard let first = name.first, let host = domain.first else { return nil }
        return "\(first)…@\(host)…"
    }
}

/// The gestures on cmux's own row of the Accounts screen.
public enum CmuxAccountAction: String, Equatable, Sendable {
    case signIn, cancelSignIn, continueInBrowser, switchAccount, signOut
}

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
    /// Why the last sign-in failed, display-safe, with its diagnostic code.
    public var failure: String?

    public init(signedIn: Bool, label: String? = nil, signingIn: Bool = false, waitingForBrowser: Bool = false, failure: String? = nil) {
        self.signedIn = signedIn
        self.label = label
        self.signingIn = signingIn
        self.waitingForBrowser = waitingForBrowser
        self.failure = failure
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

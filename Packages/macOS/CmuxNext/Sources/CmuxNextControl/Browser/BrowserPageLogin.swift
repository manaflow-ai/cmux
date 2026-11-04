/// A login the person saved for one site in the app's Secure Store, which `browser.page.fill_login`
/// fills into a page (cmux https://github.com/manaflow-ai/cmux/issues/25830). Its text never
/// prints: `description` and the debugger show the site only, so no log or trace can carry the
/// username or password.
public struct BrowserPageLogin: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The site the login was saved for (`linkedin.com`).
    public var site: String
    /// The username or email.
    public var username: String
    /// The password.
    public var password: String

    /// - Parameters:
    ///   - site: The site the login was saved for.
    ///   - username: The username or email.
    ///   - password: The password.
    public init(site: String, username: String, password: String) {
        self.site = site
        self.username = username
        self.password = password
    }

    /// The site only.
    public var description: String { "BrowserPageLogin(site: \(site))" }
    /// The site only.
    public var debugDescription: String { description }
    /// The site only.
    public var customMirror: Mirror { Mirror(self, children: ["site": site]) }
}

/// Looks up the saved login for a host (`www.linkedin.com`); nil when the person saved none.
public typealias BrowserPageLogins = @Sendable (_ host: String) async -> BrowserPageLogin?

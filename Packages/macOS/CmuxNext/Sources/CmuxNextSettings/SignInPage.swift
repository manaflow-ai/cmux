public import Foundation

/// An http(s) page where a person signs in or approves a device: a device-code page (GitHub's
/// `/login/device`, `aws sso login`'s `device.sso.*`, a Codex or OpenCode device code), an OAuth
/// authorize page, or a login page. ``LinkRouting/signInPagesInCmux`` opens one in a cmux browser
/// tab (where the person's passkeys and saved passwords work) whatever the other link settings say.
///
/// The test is on the URL alone, so every entry point agrees: a whole path segment that names a
/// sign-in step (`device`, `devicelogin`, `activate`, `login`, `signin`, `sign-in`, `oauth`,
/// `oauth2`, `authorize`, `auth`, `sso`), a host that serves only sign-ins (`login.*`, `signin.*`,
/// `accounts.*`, `device.sso.*`), or a `user_code` query item. A segment is matched whole, so
/// `auth.rs` in a repository path or `devices` in a guide's path is not a sign-in page.
///
/// ```swift
/// URL(string: "https://example.com/device?code=ABCD-1234").flatMap(SignInPage.init(url:)) // a sign-in page
/// URL(string: "https://example.com/article").flatMap(SignInPage.init(url:))               // nil
/// ```
public nonisolated struct SignInPage: Sendable, Hashable {
    /// The page's URL.
    public let url: URL

    /// The page at `url`, or nil when `url` is not an http(s) sign-in or device-code page.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let segments = url.pathComponents.map { $0.lowercased() }.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let signInHost = Self.hostPrefixes.contains { host.hasPrefix($0) }
        guard signInHost || segments.contains(where: Self.segments.contains)
            || query.contains(where: { $0.name.lowercased() == "user_code" }) else { return nil }
        self.url = url
    }

    /// Path segments that name a sign-in or device-approval step.
    private static let segments: Set<String> = [
        "device", "devicelogin", "activate", "login", "signin", "sign-in", "sign_in", "oauth", "oauth2",
        "authorize", "auth", "sso",
    ]
    /// Host prefixes of hosts that serve only sign-ins.
    private static let hostPrefixes = ["login.", "signin.", "accounts.", "device.sso."]
}

public import Foundation

/// An http(s) page where a person signs in or approves a device: a device-code page (GitHub's
/// `/login/device`, `aws sso login`'s `device.sso.*`, a Codex or OpenCode device code), an OAuth
/// authorize page, or a login page. ``LinkRouting/signInPagesInCmux`` opens one in a cmux browser
/// tab (where the person's passkeys and saved passwords work) whatever the other link settings say.
///
/// The test is on the URL alone, so every entry point agrees. A page is a sign-in page when:
/// - a `user_code` query item is in its query or its fragment (`aws sso login`, `#/device?user_code=`);
/// - a path segment is `authorize` or `devicelogin` (OAuth authorize pages, Microsoft's device page);
/// - its last segment is `login`, `signin`, `sign-in`, `sign_in` or `activate`;
/// - its last segment is `device` with a `code` query item, or in a path of at most two segments
///   (`github.com/login/device`, `auth.openai.com/codex/device`, `google.com/device`);
/// - its last segment is `auth` after an `oauth` or `oauth2` segment (Google's `/o/oauth2/v2/auth`);
/// - or its host serves only sign-ins (`signin.*`, `device.sso.*`).
///
/// Whole segments in those places only, so a repository or docs path (`golang/oauth2`,
/// `src/auth`, `studio/run/device`, `auth.rs`) is not a sign-in page.
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
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { $0.name.lowercased() }
        let fragment = url.fragment?.lowercased() ?? ""
        let last = segments.last ?? ""
        let signIn = query.contains("user_code") || fragment.contains("user_code=")
            || segments.contains("authorize") || segments.contains("devicelogin")
            || Self.lastSegments.contains(last)
            || (last == "device" && (query.contains("code") || segments.count <= 2))
            || (last == "auth" && segments.dropLast().contains { $0 == "oauth" || $0 == "oauth2" })
            || Self.hostPrefixes.contains { host.hasPrefix($0) }
        guard signIn else { return nil }
        self.url = url
    }

    /// Last path segments that name a sign-in step.
    private static let lastSegments: Set<String> = ["login", "signin", "sign-in", "sign_in", "activate"]
    /// Host prefixes of hosts that serve only sign-ins.
    private static let hostPrefixes = ["signin.", "device.sso."]
}

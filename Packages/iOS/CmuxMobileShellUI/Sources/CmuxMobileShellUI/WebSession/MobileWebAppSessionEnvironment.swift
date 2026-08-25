#if os(iOS)
import Foundation
import SwiftUI

/// Provides web session cookies that let an in-app webview render a
/// cmux-owned page as the signed-in app user.
///
/// A provider returns cookies only for a destination on the app's own web
/// allowlist; `nil` means the page loads without a native session (signed
/// out, exchange unavailable, or destination not covered) and renders as an
/// anonymous visitor. Implementations must never send credentials to a host
/// outside that allowlist.
public protocol MobileWebAppSessionProviding: Sendable {
    /// Session cookies scoped to `destination`'s host, or `nil` when no
    /// authenticated session can be established for it.
    func sessionCookies(for destination: URL) async -> [HTTPCookie]?
}

private struct MobileWebAppSessionKey: EnvironmentKey {
    static let defaultValue: (any MobileWebAppSessionProviding)? = nil
}

extension EnvironmentValues {
    /// The app-session provider in-app webviews use to render cmux-owned
    /// pages as the signed-in user. The default (`nil`, used by previews and
    /// hosts without an auth graph) loads pages without a session. A plain
    /// environment value, not an observable store, so views below list
    /// boundaries may read it (issue #2586 rule).
    public var mobileWebAppSession: (any MobileWebAppSessionProviding)? {
        get { self[MobileWebAppSessionKey.self] }
        set { self[MobileWebAppSessionKey.self] = newValue }
    }
}
#endif

public import AppKit
import Foundation

/// Where the hosted cmux sign-in opens (Debug Settings `auth.signInWindow`).
///
/// The popup is an `ASWebAuthenticationSession`. macOS hands it to the
/// default browser, and a default browser that does not host those sessions
/// ends it as `canceledLogin` (Helium, cx-13h6w; Edge, 2026-10-19: four
/// Sign In clicks in Settings, four cancels, no sign-in). The sign-in page
/// in the default browser works with every browser and has the person's
/// saved passwords, so ``automatic`` keeps the popup for Safari only
/// (cmux-cloud-config `auth::POPUP_BROWSERS`).
public nonisolated enum CloudSignInWindow: String, Sendable, CaseIterable {
    /// The popup when the default browser is Safari, else the default browser.
    case automatic
    /// Always the popup (a browser that ends it at once still falls back).
    case popup
    /// Always the default browser.
    case defaultBrowser

    /// Whether a sign-in skips the popup and opens in the default browser (Rust's `opens_default_browser`: the
    /// popup only for the browsers that host it). `defaultBrowser` is that browser's bundle identifier, nil when
    /// unknown. An FFI that does not answer keeps the popup, which still falls back to the browser.
    public func opensDefaultBrowser(defaultBrowser: String?) -> Bool {
        struct Request: Encodable { var window: String, defaultBrowser: String? }
        struct Reply: Decodable { var opensDefaultBrowser: Bool }
        return CloudStartCore().call("cloud_auth_sign_in_window", Request(window: rawValue, defaultBrowser: defaultBrowser),
                                     as: Reply.self)?.opensDefaultBrowser ?? false
    }

    /// The default browser's bundle identifier (a Launch Services lookup).
    @MainActor
    public static func currentDefaultBrowser() -> String? {
        guard let probe = URL(string: "https://cmux.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}

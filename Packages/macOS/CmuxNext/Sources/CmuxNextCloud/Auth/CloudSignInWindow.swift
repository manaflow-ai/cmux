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
    /// cmux's in-app browser tab when the app can open one, else the popup with Safari, else the default browser.
    case automatic
    /// Always cmux's in-app browser tab (the automatic rule when the app cannot open one).
    case inApp
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

    /// Where one sign-in opens (Rust's `sign_in_place`): `inApp` is whether the app can open the page in its own
    /// browser now. An FFI that does not answer keeps the older rule (``opensDefaultBrowser(defaultBrowser:)``).
    public func place(defaultBrowser: String?, inApp: Bool) -> CloudSignInPlace {
        struct Request: Encodable { var window: String, defaultBrowser: String?, inApp: Bool }
        struct Reply: Decodable { var place: String }
        if let reply = CloudStartCore().call("cloud_auth_sign_in_place",
                                             Request(window: rawValue, defaultBrowser: defaultBrowser, inApp: inApp), as: Reply.self),
           let place = CloudSignInPlace(rawValue: reply.place) { return place }
        return opensDefaultBrowser(defaultBrowser: defaultBrowser) ? .defaultBrowser : .popup
    }

    /// The default browser's bundle identifier (a Launch Services lookup).
    @MainActor
    public static func currentDefaultBrowser() -> String? {
        guard let probe = URL(string: "https://cmux.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}

/// Where one cmux sign-in opens (Rust's `auth::SignInPlace`).
public nonisolated enum CloudSignInPlace: String, Sendable {
    /// A cmux browser tab: passkeys and the emailed code work there, and the callback comes back in-process.
    case inApp
    /// The `ASWebAuthenticationSession` popup.
    case popup
    /// The person's default browser.
    case defaultBrowser
}

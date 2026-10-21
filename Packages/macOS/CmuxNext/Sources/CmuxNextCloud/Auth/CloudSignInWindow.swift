public import AppKit
import Foundation

/// Where the hosted cmux sign-in opens (Debug Settings `auth.signInWindow`).
///
/// The popup is an `ASWebAuthenticationSession`. macOS hands it to the
/// default browser, and a default browser that does not host those sessions
/// ends it as `canceledLogin` (Helium, cx-13h6w; Edge, 2026-10-19: four
/// Sign In clicks in Settings, four cancels, no sign-in). The sign-in page
/// in the default browser works with every browser and has the person's
/// saved passwords, so ``automatic`` keeps the popup for Safari only.
public nonisolated enum CloudSignInWindow: String, Sendable, CaseIterable {
    /// The popup when the default browser is Safari, else the default browser.
    case automatic
    /// Always the popup (a browser that ends it at once still falls back).
    case popup
    /// Always the default browser.
    case defaultBrowser

    /// Bundle identifiers of browsers that host the popup.
    static let popupBrowsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// Whether a sign-in skips the popup and opens in the default browser.
    /// `defaultBrowser` is that browser's bundle identifier, nil when unknown.
    public func opensDefaultBrowser(defaultBrowser: String?) -> Bool {
        switch self {
        case .popup: false
        case .defaultBrowser: true
        case .automatic: defaultBrowser.map { !Self.popupBrowsers.contains($0) } ?? false
        }
    }

    /// The default browser's bundle identifier (a Launch Services lookup).
    @MainActor
    public static func currentDefaultBrowser() -> String? {
        guard let probe = URL(string: "https://cmux.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}

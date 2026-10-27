import AppKit
import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// Where the hosted cmux sign-in opens (Debug Settings `auth.signInWindow`).
///
/// The popup is an `ASWebAuthenticationSession`. macOS hands it to the
/// default browser, and a default browser that does not host those sessions
/// ends it as `canceledLogin` (Helium, cx-13h6w; Edge, 2026-10-19: four
/// Sign In clicks in Settings, four cancels, no sign-in). The sign-in page
/// in the default browser works with every browser and has the person's
/// saved passwords, so ``automatic`` keeps the popup for Safari only.
///
/// Accounts decides it, from Launch Services and the Debug Settings choice (``SignInWindowChoice``):
/// CmuxNextCloud's `CloudAuth` asks only `opensDefaultBrowser`, so it needs no AppKit (p15-oracle-141).
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

    /// The default browser's bundle identifier, asked on the system lane (Launch Services, then the app's
    /// Info.plist); nil when no app opens https links or it has no identifier.
    public static func defaultBrowserQuery() -> WorkspaceQuery<String?> {
        WorkspaceQuery(id: "cloud.defaultBrowser", refreshes: true) { system in
            guard let probe = URL(string: "https://cmux.com"), let app = system.defaultApplication(toOpen: probe) else { return nil }
            return Bundle(url: app)?.bundleIdentifier
        }
    }

    /// `CloudAuth.opensDefaultBrowser`: the window `choice` names, against the default browser as `queries` keep
    /// it. It asks the default browser now at best effort, so a sign-in finds it kept; a miss asks again at
    /// user-blocking priority and keeps the popup for that sign-in (an unknown browser).
    @MainActor
    public static func opensDefaultBrowser(choice: @escaping @MainActor () -> CloudSignInWindow,
                                    queries: WorkspaceQueries) -> @MainActor () -> Bool {
        let query = defaultBrowserQuery()
        queries.prefetch([query], priority: .bestEffort)
        return {
            let kept = queries.cached(query)
            if kept == nil { queries.prefetch([query], priority: .userBlocking) }
            return choice().opensDefaultBrowser(defaultBrowser: kept ?? nil)
        }
    }

    /// `CloudAuth`'s open of an https sign-in page: it always has a browser (Safari is on the sealed system
    /// volume), so no Launch Services check waits on the main thread; the open runs off it (cx-050n).
    @MainActor
    public static func openExternalURL(_ url: URL) {
        NSWorkspace.shared.openInBackground(url)
    }
}

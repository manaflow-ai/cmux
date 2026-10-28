package import CmuxNextBrowser
package import Foundation

/// What a sign-in window needs from the app that hosts it: the Chromium
/// page and where a link out of the sign-in opens. The app's services
/// conform (`AppServices+WebAuthHost`) with one-line forwards; a test can
/// pass a fake that records each call.
@MainActor
package protocol WebAuthHost: AnyObject {
    /// A new Chromium page for a sign-in (the app's one Chromium engine).
    func makeSignInPage(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab
    /// Opens a link out of a sign-in page (terms, help) as a normal tab.
    func openSignInLink(_ url: URL)
}

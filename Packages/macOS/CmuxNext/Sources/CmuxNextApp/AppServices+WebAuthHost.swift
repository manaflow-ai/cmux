import CmuxNextBrowser
import CmuxNextPopups
import Foundation

/// The app side of other apps' sign-in windows (`WebAuthSessionWindows`).
extension AppServices: WebAuthHost {
    func makeSignInPage(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab { try await cache.cef.makeTab(configuration) }
    func openSignInLink(_ url: URL) { externalOpen.openWebLink(url) }
}

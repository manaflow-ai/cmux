import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Moving and duplicating a tab into another browser profile. A page's
/// session state (cookies, logins, storage, back/forward history) belongs to
/// its profile's store, so the URL reopens in the target and nothing else
/// moves; the new page says so (data-model.md 5).
extension BrowserProfileService {
    /// Reopens `tab`'s current URL in `profile` on the same engine in the
    /// same pane, then (when `closingOriginal`) closes the original once the
    /// new tab exists, so a pane never empties.
    func reopen(_ tab: TabModel, in pane: PaneModel, profile: String, closingOriginal: Bool, notice: String?) {
        let url = currentURL(of: tab)
        let originalID = tab.id
        let registry = services.registry
        let close: @MainActor (SurfaceID) -> Void = { _ in
            guard closingOriginal else { return }
            registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: originalID)))
        }
        if let controller = services.paneController(for: pane) {
            controller.newBrowserTab(url: URL(string: url), inherited: tab.browserEngine, profile: profile, notice: notice, then: close)
            return
        }
        // The pane is not on screen: create the tab there directly.
        let browserTabs = services.cache.browserTabs!
        guard case .open(let choice) = browserTabs.resolve(requested: nil, inherited: tab.browserEngine) else { return }
        let handle = pane.handle
        services.registry.track(Task {
            do {
                let surface = try await browserTabs.open(choice, in: handle, url: url, profile: profile, notice: notice)
                close(surface)
                return nil
            } catch {
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }

    /// The URL a reopened copy starts on: the live page's, else the record's.
    func currentURL(of tab: TabModel) -> String {
        services.cache.existingBrowser(tab.id)?.tab.state.url?.absoluteString
            ?? services.cache.browserTabs.startURL(for: tab)
            ?? BrowserNewTabPage.blankURL
    }

    /// Checks that `tab` can move to `profile`: a normal browser tab in
    /// another profile.
    func requireMovable(_ tab: TabModel, to profile: String, allowSame: Bool) throws {
        guard tab.kind == .browser, tab.isFrontendOwned else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.notBrowserTab) }
        guard !services.cache.browserTabs.isIncognitoTab(tab.id) else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.incognitoTab) }
        if !allowSame, profileID(ofTab: tab) == profile { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.alreadyInProfile) }
    }
}

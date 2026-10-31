import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextCompat
import Foundation

/// Moving and duplicating a tab into another browser profile. A page's
/// session state (cookies, logins, storage, back/forward history) belongs to
/// its profile's store, so only the URL goes to the target; a move keeps the
/// tab and reloads its page there, a duplicate opens a new tab (data-model.md 5).
extension BrowserProfileService {
    /// Moves `tab` to `profile` in place: the daemon changes the record (`frontend-browser-tab-profile-v1`),
    /// and `followRecordProfiles` re-makes the page in the new store. Another machine's tab or an older
    /// daemon: the URL reopens in a new tab and the original closes.
    func move(_ tab: TabModel, in pane: PaneModel, to profile: String, notice: String?) {
        let daemon = services.machines.daemon(forTab: tab)
        guard daemon.isLocal, daemon.supports(DaemonCapability.frontendBrowserTabProfile.rawValue) else {
            return reopen(tab, in: pane, profile: profile, closingOriginal: true, notice: notice)
        }
        let (surface, key, browserTabs) = (tab.surface, tab.id, services.cache.browserTabs)
        if let notice { browserTabs.setNotice(notice, forKey: key) }  // before the reply (the page can be re-made first); dropped on a refusal
        logger.info("browser profile move \(key, privacy: .public) to \(profile, privacy: .public)")
        daemon.send("set-frontend-browser-tab-profile", onFailure: { _ in _ = browserTabs.takeNotice(forKey: key) }) { try await $0.setFrontendBrowserTabProfile(surface, profileID: profile) }
    }

    /// The engine adapter half of a move: whenever a live web page's store differs from the one its tab
    /// record names (the daemon moved the tab), the page is re-made in the record's store
    /// (`TabContentCache.recreatePage`). Event-driven: tab records and page installs are observed.
    func followRecordProfiles() {
        recordProfileObservation?.cancel()
        recordProfileObservation = Task { [weak self] in
            for await stale in ObservationStream({ [weak self] in self?.pagesInOtherStores() ?? [] }) {
                for (key, profile, url) in stale {
                    self?.logger.info("browser profile store change \(key, privacy: .public): re-making its page")
                    self?.services.cache.recreatePage(key, in: profile, url: url)
                }
            }
        }
    }

    /// Live web pages of this Mac's tab records whose store is not the one the record names.
    private func pagesInOtherStores() -> [(String, BrowserProfileID, URL)] {
        let cache = services.cache
        _ = cache.pageInstalls.revision
        return cache.browsers.compactMap { key, entry in
            let page = entry.tab
            guard page is WebKitTab || page is CEFTab, let tab = cache.browserTabs.tabModel(key), tab.isFrontendOwned,
                  services.machines.daemon(forTab: tab).isLocal, !cache.browserTabs.isIncognitoTab(key),
                  !services.browserStores.offTheRecord.isOffTheRecord(page.profileID) else { return nil }  // never into a stored profile
            let profile = book.engineProfile(for: tab.browserProfileID)
            guard page.profileID != profile, let url = page.state.url ?? tab.url.flatMap(URL.init(string:)),
                  ["http", "https", "about"].contains(url.scheme ?? "") else { return nil }
            return (key, profile, url)
        }
    }

    /// Reopens `tab`'s current URL in `profile` on the same engine in the
    /// same pane, then (when `closingOriginal`) closes the original once the
    /// new tab exists, so a pane never empties.
    func reopen(_ tab: TabModel, in pane: PaneModel, profile: String, closingOriginal: Bool, notice: String?) {
        let url = currentURL(of: tab)
        let originalID = tab.id
        let registry = services.registry
        let close: @MainActor (SurfaceID) -> Void = { _ in
            guard closingOriginal else { return }
            registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: originalID), origin: .script)) // replaced: never asks
        }
        if let controller = services.paneController(for: pane) {
            controller.newBrowserTab(url: URL(string: url), inherited: tab.browserEngine, profile: profile, notice: notice, then: close)
            return
        }
        // The pane is not on screen: create the tab there directly.
        let browserTabs = services.cache.browserTabs
        guard case .open(let choice) = browserTabs.resolve(requested: nil, inherited: tab.browserEngine) else { return }
        services.registry.track(Task {
            do {
                let surface = try await browserTabs.open(choice, in: pane, url: url, profile: profile, notice: notice)
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
            ?? services.cache.browserTabs.lastURL(for: tab)
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

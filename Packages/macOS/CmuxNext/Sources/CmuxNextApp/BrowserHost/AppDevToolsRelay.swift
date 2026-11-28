import CmuxNextBrowser
import CmuxNextBrowserHost
import CmuxNextDaemon
import Foundation
import Observation

/// The CEF raw DevTools relay for the browser host: an agent's first touch
/// makes the tab's page agent-ready (marked, rebuilt when a password could
/// already be filled, woken from hibernation, created in the background when
/// it was never shown), then raw messages go through the shim
/// (`CEFAgentRelay`).
final class AppDevToolsRelay: ProviderDevToolsRelay {
    private weak var services: AppServices?
    private weak var marking: (any ProviderAgentMarking)?
    /// Whether the app announces tab `id` to the host (local, not incognito).
    var drivable: ((String) -> Bool)?
    /// Where a hidden driven tab renders (shared with the WebKit tabs).
    var renderWindows: AgentRenderWindows?
    private var relayed: [String: WeakCEFTab] = [:]

    /// A page may be replaced a few times while it starts (rebuild, wake);
    /// the provider's deadline bounds the wait in time.
    private static let maxPageInstalls = 64

    init(services: AppServices, marking: any ProviderAgentMarking) {
        self.services = services
        self.marking = marking
    }

    func prepareRelay(targetID: String) async -> Bool {
        guard let services, drivable?(targetID) == true, let (tab, _) = services.locateTab(targetID),
              tab.browserEngine == BrowserEngineTag.cef.rawValue else { return false }
        marking?.agentWillDrive(targetID: targetID)
        guard let page = await agentReadyPage(tab) else { return false }
        if !page.agentRelay.hasBrowser { page.agentRelay.createBrowser() }
        let created = await page.agentRelay.browserCreated()
        if created { keepRendering(targetID) }
        return created
    }

    /// A driven Chromium tab whose pane window is in no app window renders
    /// in the off-screen render window (``AgentRenderWindows``).
    private func keepRendering(_ targetID: String) {
        guard let services, let renderWindows, let entry = services.cache.existingBrowser(targetID),
              let page = entry.tab as? CEFTab, page.agentRelay.needsRenderWindow else { return }
        _ = renderWindows.keepRendering(tabID: targetID, chrome: entry.chrome, webView: nil)
    }

    /// The tab's live Chromium page once it is agent-driven, starting it
    /// when only a placeholder (hibernated, deferred) or nothing exists.
    private func agentReadyPage(_ tab: TabModel) async -> CEFTab? {
        guard let services else { return nil }
        let cache: TabContentCache = services.cache
        let key = tab.id
        var installs = 0
        while installs < Self.maxPageInstalls, !Task.isCancelled {
            switch cache.existingBrowser(key)?.tab {
            case let page as CEFTab where page.isAgentDriven:
                return page
            case is CEFTab:
                // A live page that is not agent-driven yet: marked, and
                // rebuilt (it may hold a filled password); wait for the new one.
                marking?.agentWillDrive(targetID: key)
            case is HibernatedBrowserTab:
                _ = cache.hibernation?.wake(key)
            case is DeferredBrowserTab:
                cache.startDeferred(key, url: nil)
            case nil:
                guard let model = services.locateTab(key)?.0 else { return nil }
                _ = cache.browser(for: model)
            default:
                // A WebKit page for a Chromium record: CEF is not available.
                return nil
            }
            if let page = cache.existingBrowser(key)?.tab as? CEFTab, page.isAgentDriven { return page }
            await nextPageInstall()
            installs += 1
        }
        return nil
    }

    /// Resumes at the next page install anywhere in the app (`pageInstalls`),
    /// or when the waiting task is cancelled (the provider's prepare deadline).
    private func nextPageInstall() async {
        guard let services else { return }
        let installs = services.cache.pageInstalls
        let installed = OneShot<Bool>()
        withObservationTracking {
            _ = installs.revision
        } onChange: {
            installed.resolve(true)
        }
        // concurrency-allow: OneShot.wait is an async suspension, not a blocking wait
        _ = await installed.wait(cancelled: false)
    }

    func startRelay(targetID: String, onMessage: @escaping (String) -> Void, onEnd: @escaping () -> Void) -> Bool {
        guard let services, let page = services.cache.existingBrowser(targetID)?.tab as? CEFTab, page.agentRelay.hasBrowser else { return false }
        page.agentRelay.set(onMessage: onMessage, onEnd: onEnd)
        relayed[targetID] = WeakCEFTab(page: page)
        return true
    }

    func send(targetID: String, message: String) -> CEFDevToolsRawSend {
        // A pane that showed the tab may have let it go since the last call.
        if relayed[targetID]?.page?.agentRelay.needsRenderWindow == true { keepRendering(targetID) }
        return relayed[targetID]?.page?.agentRelay.send(message) ?? .noBrowser
    }

    func stopRelay(targetID: String) {
        relayed.removeValue(forKey: targetID)?.page?.agentRelay.set(onMessage: nil, onEnd: nil)
    }
}

private struct WeakCEFTab {
    weak var page: CEFTab?
}

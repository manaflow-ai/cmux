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
    private unowned let services: AppServices
    private weak var marking: (any ProviderAgentMarking)?
    private var relayed: [String: WeakCEFTab] = [:]

    /// A page may be replaced a few times while it starts (rebuild, wake);
    /// the provider's deadline bounds the wait in time.
    private static let maxPageInstalls = 64

    init(services: AppServices, marking: any ProviderAgentMarking) {
        self.services = services
        self.marking = marking
    }

    func prepareRelay(targetID: String) async -> Bool {
        guard let (tab, _) = services.locateTab(targetID), tab.browserEngine == BrowserEngineTag.cef.rawValue else { return false }
        marking?.agentWillDrive(targetID: targetID)
        guard let page = await agentReadyPage(tab) else { return false }
        if !page.agentRelay.hasBrowser { page.agentRelay.createBrowser() }
        return await page.agentRelay.browserCreated()
    }

    /// The tab's live Chromium page once it is agent-driven, starting it
    /// when only a placeholder (hibernated, deferred) or nothing exists.
    private func agentReadyPage(_ tab: TabModel) async -> CEFTab? {
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

    /// Resumes at the next page install anywhere in the app (`pageInstalls`).
    private func nextPageInstall() async {
        let installs = services.cache.pageInstalls
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = installs.revision
            } onChange: {
                continuation.resume()
            }
        }
    }

    func startRelay(targetID: String, onMessage: @escaping (String) -> Void, onEnd: @escaping () -> Void) -> Bool {
        guard let page = services.cache.existingBrowser(targetID)?.tab as? CEFTab, page.agentRelay.hasBrowser else { return false }
        page.agentRelay.set(onMessage: onMessage, onEnd: onEnd)
        relayed[targetID] = WeakCEFTab(page: page)
        return true
    }

    func send(targetID: String, message: String) -> CEFDevToolsRawSend {
        relayed[targetID]?.page?.agentRelay.send(message) ?? .noBrowser
    }

    func stopRelay(targetID: String) {
        relayed.removeValue(forKey: targetID)?.page?.agentRelay.set(onMessage: nil, onEnd: nil)
    }
}

private struct WeakCEFTab {
    weak var page: CEFTab?
}

import CmuxBrowser
import CmuxSettings
import Foundation
import WebKit

/// Hosting a page of a non-WebKit engine (Chromium) in a browser panel.
///
/// A WebKit panel never takes these paths: ``BrowserPanel/enginePage`` is
/// `nil`, and every caller checks it first.
extension BrowserPanel {
    /// The result of choosing a panel's engine at creation.
    struct EnginePageSetup {
        /// The non-WebKit page, or `nil` for a WebKit panel.
        var page: (any BrowserPage)?
        /// The fallback reason to show, once per run; `nil` otherwise.
        var notice: BrowserEngineUnavailableReason?
        /// Why the panel opened in WebKit although another engine was
        /// wanted, every time (automation reports it); `nil` otherwise.
        var fallback: BrowserEngineUnavailableReason?
    }

    /// Creates the page for a new panel's engine.
    ///
    /// Without an explicit `choice`, the panel follows `CMUX_BROWSER_ENGINE`
    /// and `browser.engine`. A Chromium page that cannot be created opens the
    /// panel in WebKit with the reason as a notice.
    static func makeEnginePage(
        choice: BrowserEngineChoice?,
        panelID: UUID,
        profileID: UUID,
        runtime: BrowserEngineRuntime? = nil
    ) -> EnginePageSetup {
        let runtime = runtime ?? .shared
        let resolved: BrowserEngineChoice
        if let choice {
            resolved = choice
        } else {
            switch runtime.resolve(requested: nil) {
            case .open(let choice):
                resolved = choice
            case .refuse(_, let reason):
                // Only explicit requests are refused, and there is none here.
                resolved = BrowserEngineChoice(engine: .webkit, fallback: reason, source: .setting)
            }
        }
        guard resolved.engine != .webkit else {
            return EnginePageSetup(
                page: nil,
                notice: noticeIfFirst(resolved.fallback, runtime: runtime),
                fallback: resolved.fallback
            )
        }
        do {
            let page = try runtime.registry.makePage(
                resolved.engine,
                BrowserPageConfiguration(
                    panelID: panelID,
                    profileID: profileID,
                    zoom: BrowserZoomSettings().current(defaults: .standard)
                )
            )
            return EnginePageSetup(page: page, notice: nil)
        } catch BrowserEngineError.unavailable(_, let reason) {
            return EnginePageSetup(page: nil, notice: noticeIfFirst(reason, runtime: runtime), fallback: reason)
        } catch {
            let reason = BrowserEngineUnavailableReason.startFailed(String(describing: error))
            return EnginePageSetup(page: nil, notice: noticeIfFirst(reason, runtime: runtime), fallback: reason)
        }
    }

    /// Resolves the engine for a new panel, or `nil` when an explicitly
    /// requested engine is unavailable (the caller opens nothing; automation
    /// reports `engine_unavailable` before it gets here).
    static func resolvedEngineChoice(
        requested: BrowserEngineKind?,
        runtime: BrowserEngineRuntime? = nil
    ) -> BrowserEngineChoice? {
        switch (runtime ?? .shared).resolve(requested: requested) {
        case .open(let choice):
            return choice
        case .refuse:
            return nil
        }
    }

    private static func noticeIfFirst(
        _ reason: BrowserEngineUnavailableReason?,
        runtime: BrowserEngineRuntime
    ) -> BrowserEngineUnavailableReason? {
        guard let reason, runtime.fallbackNotices.recordFallback(reason) else { return nil }
        return reason
    }

    /// The engine a session snapshot records: `nil` for WebKit, so default
    /// snapshots stay byte-identical.
    var sessionSnapshotEngine: BrowserEngineKind? {
        engineKind == .webkit ? nil : engineKind
    }

    /// The engine a restored panel opens with: the snapshot's engine (WebKit
    /// when it has none) inherited, so `CMUX_BROWSER_ENGINE` still wins and
    /// an unavailable Chromium falls back to WebKit with the notice.
    static func restoredEngineChoice(
        _ engine: BrowserEngineKind?,
        runtime: BrowserEngineRuntime? = nil
    ) -> BrowserEngineChoice {
        switch (runtime ?? .shared).resolve(requested: nil, inherited: engine ?? .webkit) {
        case .open(let choice):
            return choice
        case .refuse(_, let reason):
            return BrowserEngineChoice(engine: .webkit, fallback: reason, source: .inherited)
        }
    }

    /// The panel's page when it is not WebKit; `nil` for WebKit panels.
    /// Automation uses it to take its Chromium paths.
    var automationEnginePage: (any BrowserPage)? {
        enginePage
    }

    /// Starts mirroring the non-WebKit page's events into the panel.
    func startEnginePageEvents() {
        guard let enginePage, enginePageEventsTask == nil else { return }
        syncAgentNavigationGuard()
        ChromiumHelperCrashWatch.startIfNeeded()
        enginePageDelegate.panel = self
        enginePage.uiDelegate = enginePageDelegate
        attachEnginePageFeatures()
        applyEnginePageState(enginePage.state)
        let events = enginePage.events
        enginePageEventsTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                self.handleEnginePageEvent(event)
            }
        }
    }

    /// Applies one page event (internal for tests).
    func handleEnginePageEvent(_ event: BrowserPageEvent) {
        noteEnginePageSafetyEvent(event)
        switch event {
        case .stateChanged(let state):
            applyEnginePageState(state)
        case .faviconChanged(let data):
            applyEnginePageFavicon(data)
        case .navigationFinished(let url):
            historyStore.recordVisit(url: url, title: pageTitle)
        case .closeRequested:
            webViewDidRequestClose?()
        case .devToolsVisibilityChanged(let open):
            isEngineDevToolsOpen = open
        case .navigationFailed(let url, _, _, _):
            // A Chromium runtime that failed to start reports it as a failed
            // load: the panel opens the page in WebKit instead of staying blank.
            if let enginePage, let reason = engineRuntime.availability(for: enginePage.engineKind).unavailableReason {
                fallBackToWebKit(reason: reason)
                return
            }
            applyEnginePageNavigationFailure(url: url)
        default:
            break
        }
    }

    /// Loads a request that already passed the panel's navigation policy
    /// (allowlist, insecure HTTP, Cloud routing) in the non-WebKit page.
    func routeNavigationToEnginePage(
        _ enginePage: any BrowserPage,
        request: URLRequest,
        recordTypedNavigation: Bool,
        onNavigationStarted: ((WKNavigation?) -> Void)?
    ) {
        shouldRenderWebView = true
        if let url = request.url {
            if recordTypedNavigation {
                historyStore.recordTypedNavigation(url: url)
            }
        }
        enginePage.load(request)
        onNavigationStarted?(nil)
    }

    /// Closes the non-WebKit page and stops mirroring it. Idempotent.
    func closeEnginePage() {
        enginePageEventsTask?.cancel()
        enginePageEventsTask = nil
        enginePage?.close()
    }
}

/// Web Inspector stays owned by the panel; ``BrowserPanel/page`` forwards to it.
extension BrowserPanel: WebKitBrowserPageDevToolsControlling {}

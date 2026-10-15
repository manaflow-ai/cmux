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
#if DEBUG
        if let reason {
            cmuxDebugLog("browser.engine.fallback at_open reason=\(reason.code) detail=\(reason.detail ?? "")")
        }
#endif
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

    /// Gives a non-WebKit page the pane's theme color until its first frame,
    /// so it does not flash gray. The page's own background stays its default.
    func applyEnginePagePlaceholderColor() {
        guard let page = enginePage as? any BrowserPagePlaceholderColoring else { return }
        page.placeholderColor = GhosttyBackgroundTheme.currentColor()
    }

    /// Starts mirroring the non-WebKit page's events into the panel.
    func startEnginePageEvents() {
        guard let enginePage, enginePageEventsTask == nil else { return }
        applyEnginePagePlaceholderColor()
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
        case .navigationCommitted:
            finishEngineNavigation(failure: nil)
        case .navigationFinished(let url):
            finishEngineNavigation(failure: nil)
            historyStore.recordVisit(url: url, title: pageTitle)
        case .closeRequested:
            webViewDidRequestClose?()
        case .devToolsVisibilityChanged(let open):
            isEngineDevToolsOpen = open
        case .navigationFailed(let url, let code, _, _):
            // A Chromium runtime that failed to start reports it as a failed
            // load: the panel opens the page in WebKit instead of staying blank.
            if let enginePage, let reason = engineRuntime.availability(for: enginePage.engineKind).unavailableReason {
                fallBackToWebKit(reason: reason)
                return
            }
            // ERR_ABORTED (-3) is a load that a newer one (a reload, the
            // next navigation) replaced: it must not fail the newer load's wait.
            if code != Self.engineAbortedErrorCode {
                finishEngineNavigation(failure: "navigation failed")
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
        // A WKNavigation-shaped callback cannot carry an engine load; tie the
        // load to automation's pending wait instead, and finish it from page events.
        associateEngineNavigation(targetURL: request.url)
    }

    /// Steps a non-WebKit page's history.
    ///
    /// A person's Back and Forward follow the engine (Chromium skips entries
    /// a page added without a user gesture, as Chrome's back button does).
    /// Automation steps exactly one entry, as `history.back()` would, through
    /// the DevTools Protocol when the engine has it, so a script's own
    /// navigations are not skipped.
    func goEngineHistory(_ page: any BrowserPage, offset: Int, dialogOwner: BrowserDialogOwner) {
        guard dialogOwner == .automation, page.capabilities.contains(.devToolsProtocol) else {
            offset < 0 ? page.goBack() : page.goForward()
            return
        }
        Task { @MainActor [weak page] in
            guard let page else { return }
            guard let historyData = try? await page.sendDevToolsProtocolMessage(method: "Page.getNavigationHistory", params: nil),
                  let entryID = BrowserPanel.historyEntryID(in: historyData, offset: offset),
                  let params = try? JSONSerialization.data(withJSONObject: ["entryId": entryID]),
                  (try? await page.sendDevToolsProtocolMessage(method: "Page.navigateToHistoryEntry", params: params)) != nil else {
                offset < 0 ? page.goBack() : page.goForward()
                return
            }
        }
    }

    /// The id of the history entry `offset` steps from the current one in a
    /// `Page.getNavigationHistory` result, nil when there is none.
    nonisolated static func historyEntryID(in result: Data, offset: Int) -> Int? {
        guard let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
              let current = object["currentIndex"] as? Int,
              let entries = object["entries"] as? [[String: Any]] else { return nil }
        let target = current + offset
        guard entries.indices.contains(target) else { return nil }
        return entries[target]["id"] as? Int
    }

    /// Chromium's `net::ERR_ABORTED`: a load replaced by a newer one.
    static let engineAbortedErrorCode = -3

    /// A load the engine page started, as automation's navigation identity.
    private final class EngineNavigationToken {}

    /// Associates the engine page's newest load with automation's waiting
    /// navigation ticket, if one is pending.
    func associateEngineNavigation(targetURL: URL?) {
        let token = EngineNavigationToken()
        activeEngineNavigationToken = token
        automationNavigationCoordinator.didAssociate(
            instanceID: webViewInstanceID,
            navigationID: ObjectIdentifier(token),
            targetURL: targetURL
        )
    }

    /// Finishes automation's wait for the engine page's newest load.
    func finishEngineNavigation(failure: String?) {
        guard let token = activeEngineNavigationToken else { return }
        activeEngineNavigationToken = nil
        if let failure {
            automationNavigationCoordinator.didFail(
                instanceID: webViewInstanceID, navigationID: ObjectIdentifier(token), message: failure
            )
        } else {
            automationNavigationCoordinator.didCommit(instanceID: webViewInstanceID, navigationID: ObjectIdentifier(token))
        }
    }

    /// Reloads the non-WebKit page for automation and ties the reload to its ticket.
    func beginEngineReloadForAutomation(_ page: any BrowserPage, targetURL: URL) {
        page.reload()
        associateEngineNavigation(targetURL: targetURL)
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

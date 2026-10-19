import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextOnboarding
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTabs
import Foundation

/// Runs a new tab page's close on the frame after its replacement shows.
@MainActor private let closeFrame = FrameBatcher(owner: "NewTabPage.close")

extension NewTabPage {
    /// Panes whose New Tab page opening runs in this main-actor turn.
    private static var openingPanes: Set<ObjectIdentifier> = []
    /// The New Tab page in `pane`, adopting the window's prewarmed spare when it has one
    /// (NewTabSparePool), else loading cold. A static of the page, not the pane (the godfile
    /// limit counts PaneController's extensions). Everything happens in this one main-actor
    /// turn, with no hop: the spare waited at this pane's content size, so its adoption changes
    /// no size and WebKit shows the page at its final layout; the strip starts the tab's grow now;
    /// and the turn's one commit puts the tab and the page on screen in the same frame.
    /// `reusingShown` (Focus Location Bar, an empty submit): a New Tab page the pane already
    /// shows takes the keyboard instead. Otherwise (Cmd-T) a new tab opens, also from a New Tab
    /// page (Leo 2026-10-10).
    static func open(in pane: PaneController, seed: AgentPaneSeedSource?, reusingShown: Bool = false,
                     then: (@MainActor (String) -> Void)? = nil) {
        let start = ContinuousClock.now
        let services = pane.services
        let openingKey = ObjectIdentifier(pane)
        if reusingShown, let key = pane.currentTabKey, services.agentTabs.isNewTabPage(key), AgentHistoryPage.title(key, services) == nil {
            openingPanes.remove(openingKey)
            services.windowController(showing: pane)?.focus.send(.focusPane(pane.paneKey, source: .intent))
            services.agentTabs.view(for: key)?.focusLocation()
            return
        }
        guard openingPanes.insert(openingKey).inserted else { return }
        // Keys typed before the page's field is ready wait for it (NewTabInputBuffer).
        let inputToken = services.keyRouter.newTabInputCoordinator.begin(for: pane)
        guard inputToken != nil else {
            openingPanes.remove(openingKey)
            return
        }
        var page = Self.page(services, selected: pane.selectedTab, window: pane.view.window, pane: pane)
        // The page's folder: the selected tab's, or (an empty pane of another machine) its workspace's there.
        let cwd = page.cwd
        page.inputToken = inputToken
        var handler = Self.handler(services, cwd: cwd) { [weak pane] key, request in
            if let pane { BenchSpans.measure("newTab.replace") { Self.replace(key, with: request, cwd: request.cwd ?? cwd, in: pane) } }
        }
        handler.inputReady = { [weak pane] _, token in
            guard let pane else { return }
            pane.services.keyRouter.newTabInputCoordinator.acknowledge(token, in: pane.view.window)
        }
        // A pane of another machine shows the same page, never a prewarmed spare: a spare is connected
        // to this Mac's acpmux, and that pane's chat starts on its machine at the first send (cx-k21v).
        let spare = seed == nil && pane.daemon.isLocal
            ? BenchSpans.measure("newTab.take", { services.newTabSpares.take(for: pane.view.window, size: NewTabSparePool.newTabContentSize(in: pane)) })
            : nil
        // The tab shows at once (a store intent); the store's tab replaces it when it answers.
        guard BenchSpans.measure("newTab.open", { pane.openAgentTab(seed: seed, newTab: (page, handler), spare: spare?.view, then: then) }) else {
            openingPanes.remove(openingKey)
            services.keyRouter.newTabInputCoordinator.cancel(in: pane.view.window)
            return
        }
        openingPanes.remove(openingKey)
        // The page's tab shows: from now on the key hold ends as soon as the pane shows another tab.
        services.keyRouter.newTabInputCoordinator.didShow(in: pane.view.window)
        // The adopted page is alive: show it this frame and give it the keyboard now, so the
        // first key typed after the open reaches its field (fleet test: it went to the old responder).
        let showedSpare = spare != nil && services.presentation.showNow(pane)
        if showedSpare {
            services.windowController(showing: pane)?.focus.send(.focusPane(pane.paneKey, source: .intent))
        }
        // `showNow` already syncs the strip as part of presenting the adopted spare. Repeating
        // that full reconciliation on the same main-actor turn adds directly to the Cmd-T p95
        // budget (cx-98s). Cold pages still need the immediate strip sync because their content
        // is presented by the normal scheduler on a later frame.
        if !showedSpare {
            BenchSpans.measure("newTab.strip") { pane.view.stripView.sync(fromModel: true) }
        }
        services.newTabSpares.record(.init(spare: spare != nil, crossWindow: spare?.crossWindow == true,
                                           milliseconds: NewTabSparePool.milliseconds(since: start), refit: spare?.refit == true))
    }

    /// The page chose a terminal or browser: open it, then close the page,
    /// which held nothing yet (the open-beside rule's one replace case). The
    /// page closes only once the new tab exists, so a refused or failed open
    /// leaves it, and what was typed, in place. A chat that has a session
    /// (`keep`: its Log In, Update or Open in Terminal) stays; the new tab opens beside it.
    /// A static of the page, not the pane, so PaneController stays one
    /// responsibility (the godfile limit counts its extensions).
    static func replace(_ key: String, with request: AgentPaneOpenTab, cwd: String?, in pane: PaneController, keep chat: Bool = false) {
        let keep = chat || request.keep
        let services = pane.services
        services.keyRouter.newTabInputCoordinator.cancel(in: pane.view.window)
        openingPanes.remove(ObjectIdentifier(pane))
        // The page closes one frame after the new tab shows, so the frame that builds the
        // terminal surface does not also pay for the page (R81: 17.8 ms frames at 120 Hz).
        let close: @MainActor (SurfaceID) -> Void = { [weak pane] _ in
            guard !keep else { return }
            closeFrame.scheduleFrame { BenchSpans.measure("newTab.closePage") { pane?.close([StripTabID(key)]) } }
        }
        if case .terminal = request.kind, request.run, command(request.text) == nil { return } // opens nothing
        let closePage = keep ? close : NewTabSlot.placing(replacing: key, services: services, then: close) ?? close // the page's slot
        switch request.kind {
        case .terminal where !request.run:
            // `!` on the screen: type, never run; keys typed while the
            // terminal is made follow it in order (NewTabTypeAhead).
            let typeAhead = services.newTabTypeAhead
            if typeAhead.latest(key).isEmpty, !request.text.isEmpty { typeAhead.update(key, text: request.text) }
            pane.newTerminalTab(cwd: cwd, typingAhead: key, then: closePage)
        case .terminal:
            guard let command = command(request.text) else { return }
            pane.newTerminalTab(cwd: cwd, typing: command, then: closePage)
        case .browser:
            let resolver = services.cache.suggestionEngine.resolver
            let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = request.search
                ? resolver.searchEngine.searchURL(for: text)
                : ChromiumInternalURL(typed: text)?.url ?? resolver.commitTypoFix(for: text) ?? resolver.destination(for: request.text)?.url
            let engine = BrowserEngineTag.engine(for: url)
            // A session-local browser tab is made and selected right away.
            if services.cache.browserTabs.isAvailable(in: pane.pane) {
                pane.newBrowserTab(url: url, engine: engine, then: closePage)
            } else {
                // A refused tab (a Chromium page without Chromium) keeps the page.
                if pane.newBrowserTab(url: url, engine: engine), !keep { pane.close([StripTabID(key)]) }
            }
        case .agent:
            return
        }
    }
}

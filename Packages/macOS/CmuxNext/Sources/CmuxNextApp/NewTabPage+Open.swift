import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextInput
import CmuxNextMacScreen
import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextWakeups
import Foundation

extension NewTabPage {
    /// Panes whose New Tab page opening runs in this main-actor turn.
    private static var openingPanes: Set<ObjectIdentifier> = []
    /// The New Tab page in `pane`, adopting the window's prewarmed spare when it has one
    /// (NewTabPreload), else loading cold. A static of the page, not the pane (the godfile
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
        // A moved page (another pane, workspace or window) acts in the pane that shows it now; it
        // opened its pick in the pane it left, or nowhere once that pane closed. Its folder stays
        // the one the page shows (`page.cwd`), as a split's page does.
        var handler = Self.handler(services, cwd: cwd) { [weak pane, weak services] key, request in
            guard let target = services.flatMap({ Self.hosting(key, $0) }) ?? pane else { return }
            BenchSpans.measure("newTab.replace") { Self.replace(key, with: request, cwd: request.cwd ?? cwd, in: target) }
        }
        handler.inputReady = { [weak pane] _, token in
            guard let pane else { return }
            pane.services.keyRouter.newTabInputCoordinator.acknowledge(token, in: pane.view.window)
        }
        // A pane of another machine shows the same page, never a prewarmed spare: a spare is connected
        // to this Mac's acpmux, and that pane's chat starts on its machine at the first send (cx-k21v).
        let spare = seed == nil && pane.daemon.isLocal
            ? BenchSpans.measure("newTab.take", { services.newTabSpares.take(for: pane.view.window, size: NewTabPreload.newTabContentSize(in: pane)) })
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
                                           milliseconds: NewTabPreload.milliseconds(since: start), refit: spare?.refit == true,
                                           covered: spare?.covered == true))
    }

    /// The page chose a terminal or browser: open it, then close the page,
    /// which held nothing yet. The page closes only once the new tab exists, so a refused or failed open
    /// leaves it, and what was typed, in place. A chat that has a session
    /// (`keep`: its Log In, Update or Open in Terminal) stays; the new tab opens beside it.
    /// A static of the page, not the pane, so PaneController stays one
    /// responsibility (the godfile limit counts its extensions).
    static func replace(_ key: String, with request: AgentPaneOpenTab, cwd: String?, in pane: PaneController, keep chat: Bool = false) {
        let keep = chat || request.keep
        let services = pane.services
        services.keyRouter.newTabInputCoordinator.cancel(in: pane.view.window)
        openingPanes.remove(ObjectIdentifier(pane))
        // A pairing link (its room secret) is never searched, loaded or typed: the
        // page stays, with what was typed, and Mac Screen says why.
        if let refusal = MacScreenPages.pairingLinkRefusal(for: request.text) { return services.registry.refuse(refusal) }
        // The page closes one frame after the new tab shows, so the frame that builds the
        // terminal surface does not also pay for the page (R81: 17.8 ms frames at 120 Hz).
        let closeFrames = services.newTabCloseFrames
        let close: @MainActor (SurfaceID) -> Void = { [weak pane] _ in
            guard !keep else { return }
            closeFrames.scheduleFrame { BenchSpans.measure("newTab.closePage") { pane?.close([StripTabID(key)]) } }
        }
        if case .terminal = request.kind, request.run, command(request.text) == nil { return } // opens nothing
        // The pick takes the page's place, like a browser's new tab (Leo 2026-10-20); the Debug toggle
        // `newTab.picksFollowLinks` lands it where links do (Lawrence 2026-10-19).
        if !keep, Self.opensBeside(key, in: pane) { return Self.openBeside(key, with: request, cwd: cwd, from: pane) }
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
            let url = browserURL(request, services: services)
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

    /// Whether what New Tab page `key` in `pane` opens goes beside it: the Debug toggle
    /// `newTab.picksFollowLinks` is on, the link placement is not Same Pane, the page shares its pane
    /// with another tab (a lone page has nothing to keep in view, so it is replaced in place), and it is no split's (a split's page, which lists Open
    /// Tabs, fills the pane the person just made, NewTabPage.split). `mainPane` false for a chat pick:
    /// main pane layout keeps chats out of the column right of the chat dock (NewChatPlacement).
    static func opensBeside(_ key: String, in pane: PaneController, mainPane: Bool = true) -> Bool {
        let tabs = pane.services.agentTabs, page = tabs.resolve(key)
        guard AgentPaneTunables.newTabPicksFollowLinks.value, tabs.newTabPages[page]?.page.openTabs == nil, pane.pane.tabs.contains(where: { $0.id != page }) else { return false }
        return pane.services.linkOpener.target(from: pane, mainPane: mainPane) != .pane(pane.layoutPaneID)
    }

    /// ``replace(_:with:cwd:in:keep:)`` beside the page: the terminal or browser opens through
    /// ``LinkOpener`` (the pane on the right, else a new split), then the page closes.
    private static func openBeside(_ key: String, with request: AgentPaneOpenTab, cwd: String?, from pane: PaneController) {
        let services = pane.services
        let closePage = closingPage(key, in: pane)
        services.linkOpener.open(from: pane) { target, placed in
            let landed: @MainActor (SurfaceID) -> Void = { surface in
                placed?(surface)
                closePage()
            }
            switch request.kind {
            case .terminal where !request.run:
                let typeAhead = services.newTabTypeAhead
                if typeAhead.latest(key).isEmpty, !request.text.isEmpty { typeAhead.update(key, text: request.text) }
                target.newTerminalTab(cwd: cwd, typingAhead: key, then: landed)
                return true
            case .terminal:
                guard let command = command(request.text) else { return false }
                target.newTerminalTab(cwd: cwd, typing: command, then: landed)
                return true
            case .browser:
                let url = browserURL(request, services: services)
                return target.newBrowserTab(url: url, engine: BrowserEngineTag.engine(for: url), background: placed != nil, then: landed)
            case .agent:
                return false
            }
        }
    }

    /// The address a browser pick of the page goes to: a search, a cmux/Chromium page, or the typed
    /// destination (typos fixed).
    private static func browserURL(_ request: AgentPaneOpenTab, services: AppServices) -> URL? {
        let resolver = services.cache.suggestionEngine.resolver
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return request.search
            ? resolver.searchEngine.searchURL(for: text)
            : ChromiumInternalURL(typed: text)?.url ?? resolver.commitTypoFix(for: text) ?? resolver.destination(for: request.text)?.url
    }

    /// Closes New Tab page `key` one frame after what it opened shows (``opensBeside(_:in:)`` keeps
    /// a lone page in place, so this never empties the person's pane).
    static func closingPage(_ key: String, in pane: PaneController) -> @MainActor () -> Void {
        let closeFrames = pane.services.newTabCloseFrames
        return { [weak pane] in closeFrames.scheduleFrame { pane?.close([StripTabID(key)]) } }
    }
}

/// ``NewTabPreload``, which every New Tab page open takes from, on the app's collaborators, and its
/// pure size and timing helpers.
extension NewTabPreload {
    /// The app's adapter (`AppServices.newTabSpares`), on the app's one preload slot: made here with
    /// the app's deadlines and installed on `webUI`, whose memory pressure subscription drops it, unless
    /// installed already. Rendered-parked until spike 090 records its park state: no engine freezes a
    /// slot page yet (p13-webui-028).
    static func app(_ services: AppServices) -> NewTabPreload {
        let slot = services.webUI.preload ?? PagePreloadSlot(parkState: .renderedParked, deadlines: services.mainDeadlines)
        services.webUI.preload = slot
        return NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: services.inputTap,
                             deadlines: services.mainDeadlines,
                             preloadOnMakeVisible: services.features.isEnabled(.pageRendererAtFirstShow),
                             parksHidden: services.features.isEnabled(.newTabParksHidden))
    }

    /// The adapter on `services`' collaborators (held, not `services`).
    convenience init(services: AppServices, slot: PagePreloadSlot, memory: any MemoryConsumerRegistry,
                     input: any InputObserving, deadlines: MainDeadlineScheduler,
                     preloadOnMakeVisible: Bool = false, parksHidden: Bool = false) {
        self.init(slot: slot, agentTabs: services.agentTabs, windows: services.windows, appEvents: services.appEvents,
                  sparePage: { [weak services] in services.map { NewTabPage.sparePage($0) } },
                  memory: memory, input: input, deadlines: deadlines, preloadOnMakeVisible: preloadOnMakeVisible, parksHidden: parksHidden)
    }

    /// The size a Cmd-T tab in `pane` shows at: the pane less its tab bar, also where a browser's
    /// header band holds the bar now (the band goes with the browser).
    static func newTabContentSize(in pane: PaneController) -> NSSize {
        let scale = pane.view.window?.backingScaleFactor ?? 2
        let strip = pane.hidesTabBar || pane.isAppPane ? 0 : PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        return NSSize(width: pane.view.bounds.width, height: max(0, pane.view.bounds.height - strip))
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}

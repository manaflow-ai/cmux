import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextDaemon
import CmuxNextMacScreen
import CmuxNextOnboarding
import CmuxNextPalette
import CmuxNextSettings
import CmuxNextTabs
import Foundation
import enum CmuxNextLayout.ChatColumnPlacement
import struct CmuxNextLayout.MainPaneLayout

extension InternalPageID {
    /// The native New Tab page (`tabs.nativeNewTabPage`, ``NativeNewTabView``).
    static let nativeNewTab = InternalPageID(rawValue: "native-new-tab")
}

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
        // `tabs.nativeNewTabPage` on: the native page instead (an alternative; the web page stays the default).
        if seed == nil, let key = openNative(in: pane, reusingShown: reusingShown) {
            services.newTabSpares.record(.init(spare: false, crossWindow: false, milliseconds: NewTabSparePool.milliseconds(since: start), refit: false))
            return then?(key) ?? ()
        }
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
        var page = Self.page(services, selected: pane.selectedTab, window: pane.view.window, pane: pane, paletteActions: false)
        // The page's folder: the selected tab's, or (an empty pane of another machine) its workspace's there.
        let cwd = page.cwd
        page.inputToken = inputToken
        // A moved page (another pane, workspace or window) acts in the pane that shows it now; it
        // opened its pick in the pane it left, or nowhere once that pane closed. Its folder stays
        // the one the page shows (`page.cwd`), as a split's page does.
        let machineID = pane.daemon.machineID
        var handler = Self.handler(services, cwd: cwd) { [weak pane, weak services] key, request in
            guard let target = services.flatMap({ Self.hosting(key, $0, onMachine: machineID) }) ?? pane else { return }
            BenchSpans.measure("newTab.replace") { Self.replace(key, with: request, cwd: request.cwd ?? cwd, in: target) }
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
        fillPaletteActions(services)
    }

    /// Lists the Commands palette's actions (30-50 ms on the main thread) for the New Tab pages that
    /// show without them, on the frame after the one that shows the page, so Cmd-T and Cmd-N never
    /// wait for them. The web pages take them in place (``AgentPaneView/refreshNewTabActions(_:)``);
    /// a page with no view yet (Cmd-N's first page before its pane shows it) takes them into its
    /// stored page, so the view made from it later lists them. One pass per call, no repeat.
    static func fillPaletteActions(_ services: AppServices) {
        closeFrame.scheduleFrame {
            closeFrame.scheduleFrameFromMain { [weak services] in
                guard let services else { return }
                let tabs = services.agentTabs
                let views = tabs.newTabPages.keys.compactMap { tabs.views[$0] }.filter { $0.model.newTab?.omnibar.actions.isEmpty == true }
                let unshown = tabs.newTabPages.filter { tabs.views[$0.key] == nil && $0.value.page.omnibar.actions.isEmpty }.map(\.key)
                guard !views.isEmpty || !unshown.isEmpty else { return }
                let actions = paletteActions(services)
                for view in views { view.refreshNewTabActions(actions) }
                for key in unshown { tabs.newTabPages[key]?.page.omnibar.actions = actions }
            }
        }
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
        // A page beside a lone chat, the main pane: the pick takes the page's place, then the chat docks left and the
        // pick's pane is the column on its right, as for a link (Leo 2026-10-30: "not to fucking open it up in the
        // main fucking pane").
        let docksChat = !keep && Self.docksChat(pane)
        let close: @MainActor (SurfaceID) -> Void = { [weak pane] surface in
            guard !keep else { return }
            closeFrame.scheduleFrame { BenchSpans.measure("newTab.closePage") { pane?.close([StripTabID(key)]) } }
            if docksChat, let pane { MainPaneLayout.dockChat(of: pane, keeping: surface, focus: true, services: services) }
        }
        if case .terminal = request.kind, request.run, command(request.text) == nil { return } // opens nothing
        // The pick takes the page's place, like a browser's new tab (Leo 2026-10-20); the Debug toggle
        // `newTab.picksFollowLinks` lands it where links do (Lawrence 2026-10-19).
        // A page in the chat dock, the main pane: the pick opens in the strip beside it, whatever else the dock
        // holds (Leo 2026-10-30: "not to fucking open it up in the main fucking pane"). A setup action's `keep`
        // (Log In, Update, Open in Terminal) goes there too and leaves the page or chat in place.
        if ChatColumnPlacement.pagePick(from: pane) != nil,
           case .beside(let closesPage) = ChatColumnPlacement.DockPick.resolve(hasStrip: true, keep: keep) {
            return Self.openBeside(key, with: request, cwd: cwd, from: pane, closesPage: closesPage)
        }
        if !keep, Self.opensBeside(key, in: pane, kind: request.kind) { return Self.openBeside(key, with: request, cwd: cwd, from: pane) }
        let closePage = keep ? close : NewTabSlot.placing(replacing: key, onMachine: pane.daemon.machineID, services: services, then: close) ?? close // the page's slot
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
    static func opensBeside(_ key: String, in pane: PaneController, kind: AgentPaneTabKind? = nil, mainPane: Bool = true) -> Bool {
        let tabs = pane.services.agentTabs, page = tabs.resolve(key)
        guard AgentPaneTunables.newTabPicksFollowLinks.value, tabs.newTabPages[page]?.page.openTabs == nil, pane.pane.tabs.contains(where: { $0.id != page }) else { return false }
        return pane.services.linkOpener.target(from: pane, mainPane: mainPane, kind: kind?.rightColumnKind) != .pane(pane.layoutPaneID)
    }

    /// ``replace(_:with:cwd:in:keep:)`` beside the page: the terminal or browser opens in `strip`, else through
    /// ``LinkOpener`` (the pane on the right, else a new split), then the page closes.
    private static func openBeside(_ key: String, with request: AgentPaneOpenTab, cwd: String?, from pane: PaneController,
                                   closesPage: Bool = true) {
        let services = pane.services
        let closePage = closesPage ? closingPage(key, in: pane) : {}
        let make: LinkOpener.Make = { target, placed in
            let landed: @MainActor (SurfaceID) -> Void = { surface in
                placed?(surface)
                closePage()
            }
            switch request.kind {
            case .terminal where !request.run:
                let typeAhead = services.newTabTypeAhead
                if typeAhead.latest(key).isEmpty, !request.text.isEmpty { typeAhead.update(key, text: request.text) }
                target.newTerminalTab(cwd: cwd, typingAhead: key, placementOwner: placed != nil, then: landed)
                return true
            case .terminal:
                guard let command = command(request.text) else { return false }
                target.newTerminalTab(cwd: cwd, typing: command, placementOwner: placed != nil, then: landed)
                return true
            case .browser:
                let url = browserURL(request, services: services)
                return target.newBrowserTab(url: url, engine: BrowserEngineTag.engine(for: url), background: placed != nil,
                                            placementOwner: placed != nil, then: landed)
            case .agent:
                return false
            }
        }
        services.linkOpener.open(from: pane, kind: request.kind.rightColumnKind, make)
    }

    /// Whether a pick on a page beside a lone chat (the main pane) docks the chat left once it lands, so the
    /// pick's pane is the column on its right, as for a link from the chat.
    static func docksChat(_ pane: PaneController) -> Bool {
        MainPaneLayout.isOn(services: pane.services)
            && ChatColumnPlacement.resolve(from: pane, services: pane.services, ignoringPages: true) == .dockChat
    }

    /// The address a browser pick of the page goes to: a search, a cmux/Chromium page, or the typed
    /// destination (typos fixed).
    static func browserURL(_ request: AgentPaneOpenTab, services: AppServices) -> URL? {
        let resolver = services.cache.suggestionEngine.resolver
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return request.search
            ? resolver.searchEngine.searchURL(for: text)
            : ChromiumInternalURL(typed: text)?.url ?? resolver.commitTypoFix(for: text) ?? resolver.destination(for: request.text)?.url
    }

    /// Closes New Tab page `key` one frame after what it opened shows (``opensBeside(_:in:)`` keeps
    /// a lone page in place, so this never empties the person's pane).
    static func closingPage(_ key: String, in pane: PaneController) -> @MainActor () -> Void {
        { [weak pane] in closeFrame.scheduleFrame { pane?.close([StripTabID(key)]) } }
    }

    /// Opens the native New Tab page in `pane` when `tabs.nativeNewTabPage` is on and the pane is this
    /// Mac's (another machine's pane keeps the web page); `reusingShown` selects one already shown.
    /// Returns the page's tab key, or nil to open the web page.
    static func openNative(in pane: PaneController, reusingShown: Bool) -> String? {
        let services = pane.services
        guard services.settings?.snapshot.nativeNewTabPage == true, pane.daemon.isLocal else { return nil }
        if reusingShown, let key = pane.currentTabKey, LocalPageTab.page(of: key) == .nativeNewTab {
            services.pages.reveal(key, in: pane)
            return key
        }
        // Keys typed after Cmd-T wait for the field, as on the web page (NewTabInputCoordinator):
        // the page needs no handshake, so the hold drains once the field exists.
        let input = services.keyRouter.newTabInputCoordinator
        if let token = input.begin(for: pane) { input.acknowledge(token, in: pane.view.window) }
        if services.pages.provider(.nativeNewTab) == nil {
            // Each tab's view owns its model, made from the pane that shows the tab on its first show.
            services.pages.register(WebPageTab(.nativeNewTab, symbol: "square.grid.2x2", title: Strings.untitledBrowser,
                                               view: { [weak services] key in services?.paneController(showingTab: key).map { nativeView(key, in: $0) } }))
        }
        let opened = services.pages.open(.nativeNewTab, in: pane.pane.id, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue,
                                         window: services.windowController(showing: pane))
        // The prepared page, if one is parked (NewTabSparePool.warmNative); the pane's view for `opened` adopts it.
        let spare = services.newTabSpares.takeNative(for: opened)
        pane.apply(pane.snapshot())
        services.pages.reveal(opened, in: pane)
        // Shown in this turn, as the web page's spare is, not on the next presentation frame.
        _ = services.presentation.showNow(pane)
        if spare != nil {
            // Its field exists already: the keys held since Cmd-T go there now.
            input.didShow(in: pane.view.window)
            input.flush(in: pane.view.window)
        }
        return opened
    }

    /// Tab `key`'s native page in `pane`: the web page's context (``page(_:selected:window:pane:paletteActions:)``), no web view.
    /// The palette's actions (the slow part of that context) load on the frame after the one that shows the page, or at
    /// the first keystroke if that comes first, so Cmd-T shows the page without waiting for them.
    private static func nativeView(_ key: String, in pane: PaneController) -> NSView {
        let services = pane.services
        let page = BenchSpans.measure("newTab.nativeContext") {
            Self.page(services, selected: pane.selectedTab, window: pane.view.window, pane: pane, paletteActions: false)
        }
        let actions = nativeActions(key, cwd: page.cwd, pane: pane)
        let list: @MainActor () -> [AgentPaneOmnibar.Action] = { [weak services] in services.map(Self.paletteActions) ?? [] }
        // Cmd-T took the prepared page: it takes this tab's context, already laid out.
        if let spare = services.newTabSpares.claimNative(key), let model = spare.model {
            model.adopt(page: page, actions: actions, paletteActions: list)
            closeFrame.scheduleFrame { closeFrame.scheduleFrameFromMain { [weak model] in model?.loadPaletteActions() } }
            return spare
        }
        let model = NativeNewTabModel(page: page, actions: actions, paletteActions: list)
        closeFrame.scheduleFrame { closeFrame.scheduleFrameFromMain { [weak model] in model?.loadPaletteActions() } }
        let host = NativeNewTabView.hosted(model)
        // The page counts as shown (leaving it ends the hold) only once its field exists: until then
        // the pane may not name the page's tab yet, and the hold must keep the keys.
        host.onFieldReady = { [weak services, weak host] in
            guard let input = services?.keyRouter.newTabInputCoordinator else { return }
            input.didShow(in: host?.window)
            input.flush(in: host?.window)
        }
        return host
    }

    /// The native page's requests, over the web page's paths: `newTab.submit`'s table for typed text,
    /// the palette's switchers for jumps, the palette's own run for an action. A submit replaces the page.
    private static func nativeActions(_ key: String, cwd: String?, pane: PaneController) -> NativeNewTabActions {
        NativeNewTabActions(
            submit: { [weak pane] text, kind, search in
                guard let pane else { return }
                guard submitNative(text, kind: kind, search: search, cwd: cwd, in: pane) else { return }
                closingPage(key, in: pane)()
            },
            jump: { [weak pane] target, id in if let services = pane?.services { jump(target, id: id, services: services) } },
            action: { [weak pane] id in pane?.services.palette.runCommand(ActionID(rawValue: id), relativeTo: pane?.view.window) }
        )
    }

    /// What a native submit opens: an empty field makes the kind as it is; a terminal runs the text; a
    /// browser opens an address or searches; an agent's text goes through `newTab.submit` (a prompt, or a
    /// URL or `!command` typed there).
    static func submitNative(_ text: String, kind: AgentPaneTabKind, search: Bool, cwd: String?, in page: PaneController) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refusal = MacScreenPages.pairingLinkRefusal(for: trimmed) {
            page.services.registry.refuse(refusal)
            return false
        }
        guard let request = NewTabSubmit.nativeRequest(text: trimmed, kind: kind, search: search, cwd: cwd,
                                                       resolver: page.services.cache.suggestionEngine.resolver) else { return false }
        let chatPlacement = ChatColumnPlacement.keepsNewTabPage(in: page) || Self.docksChat(page)
        if request.kind.opensBesideChat && chatPlacement { return servicesOpenNativeTool(request, from: page) }
        switch (request.kind, request.text.isEmpty) {
        case (.terminal, _): page.newTerminalTab(cwd: cwd, typing: nativeTerminalTyping(request))
        case (.browser, true): return page.newBrowserTab()
        case (.agent, true): return page.openAgentTab(seed: AgentPaneSeedSource(AgentPaneSeed(cwd: cwd)))
        case (.browser, false), (.agent, false):
            let arguments: [String: ActionValue] = ["text": .string(request.text), "search": .bool(request.search)]
            return page.services.registry.perform(NewTabSubmit.action, invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: page.pane.id), arguments: arguments, origin: .user))
        }
        return true
    }

    /// Explicit Terminal Run appends a newline; a Browser-mode !command only types its text.
    static func nativeTerminalTyping(_ request: AgentPaneOpenTab) -> String? {
        request.run ? command(request.text) ?? nil : (request.text.isEmpty ? nil : request.text)
    }

    private static func servicesOpenNativeTool(_ request: AgentPaneOpenTab, from page: PaneController) -> Bool {
        let services = page.services
        return services.linkOpener.open(from: page, kind: request.kind.rightColumnKind) { target, placed in
            switch request.kind {
            case .terminal:
                let typing = nativeTerminalTyping(request)
                target.newTerminalTab(cwd: request.cwd, typing: typing, placementOwner: placed != nil) { surface in placed?(surface) }; return true
            case .browser:
                let url = browserURL(request, services: services)
                return target.newBrowserTab(url: url, engine: BrowserEngineTag.engine(for: url), background: placed != nil, placementOwner: placed != nil) { surface in placed?(surface) }
            case .agent: return false
            }
        }
    }
}

/// A focused pane gives the native New Tab page's field the keyboard (``InternalPageView/focusTarget``).
extension NativeNewTabHostingView: InternalPageFocusing {
    var focusTarget: NSView { fieldView ?? self }
}

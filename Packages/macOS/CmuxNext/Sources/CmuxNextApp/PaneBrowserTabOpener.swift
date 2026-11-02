import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextPages
import CmuxNextRemoteLocalhostService
import CmuxNextTabs

/// Opens a browser tab in one pane: daemon-owned when supported, on the
/// engine `BrowserTabService.resolve` picks (an explicit engine, else
/// `browser.defaultEngine`, Chromium, with the WebKit fallback), else
/// session-local. The new tab is selected and focused when it lands; a
/// blank tab focuses its address bar so the user can type a URL.
/// `PaneController.newBrowserTab` is its entry point; a value is made per
/// request and holds its pane until the daemon's answer.
@MainActor
struct PaneBrowserTabOpener {
    let controller: PaneController

    /// `inherited` is a reopened or duplicated tab's engine or a popup
    /// opener's (falls back instead of refusing). `adopting` is a popup page
    /// the engine already created (`BrowserPageRequests`). `background` (a
    /// page's Cmd-click) creates the tab without selecting it. `profile` is
    /// an explicit browser profile (else the workspace's, the room's or
    /// `default`); `notice` shows on the new page; `then` runs with the new
    /// surface once the daemon made the tab. `opener` is the tab of the page
    /// that asked for it: the new tab goes next to it in Chrome's order
    /// (`BrowserTabOpeners`); without it the tab goes to the end.
    /// False when the tab is refused (no tab, no daemon request). A local file goes where
    /// `LocalFileHandoff` shows it (a tab's first load is not guarded): Markdown opens the markdown
    /// page unless the caller waits for the tab, and media Chromium cannot play opens in WebKit.
    func open(url: URL?, engine requested: String?, inherited: String?, adopting child: (any BrowserTab)?, // perf-hot: 10ms new-tab (the key's turn of every new browser tab)
              background: Bool, profile: String?, notice: String?, opener: SurfaceID?,
              placementOwner: Bool = false, then: (@MainActor (SurfaceID) -> Void)?) -> Bool {
        let services = controller.services
        var target = url
        // chrome://history and chrome://bookmarks open cmux's pages; chrome://settings opens Settings
        // and cmux://mac-screen the Mac Screen tab, and no browser tab (false, so a New Tab page that
        // asked stays in place).
        if child == nil, let typed = target {
            guard let routed = ChromiumPageRouter.routed(typed, services: services, focus: !background, in: controller) else { return false }
            target = routed
        }
        if child == nil, then == nil, let url = target, services.viewers.openMarkdownHandoff(url, in: controller, focus: !background) {
            return true
        }
        // `browser.enabled` off: a web page goes to the default browser, a file to its app, a blank tab is refused.
        guard BrowserAvailability(enabled: services.cache.browserTabs.browserEnabled()).allows(target?.absoluteString) else {
            child?.close()
            if let target, target.isFileURL {
                LinkRouter.shared.openFile(target)
            } else if let target, ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
                LinkRouter.shared.open(target, in: .system)
            } else {
                services.registry.refuse(MiscHandlerStrings.browserOff)
            }
            return false
        }
        let daemon = controller.daemon
        // A new tab in another machine's workspace runs on that machine
        // (cx-2cob, decided 2026-10-09): its record names the machine; the
        // page says when it is not ready and offers Open Locally Instead.
        let placement = child == nil && inherited == nil
            ? BrowserPlacement.resolve(isLocal: daemon.isLocal, machine: daemon.machineID,
                                       hostAvailable: services.cache.browserTabs.browserHostAvailable(daemon.machineID)) : .local
        let url = placement.address(for: target)
        let onMachine = MachineBrowserRecord.matches(url)
        let requested = onMachine ? nil : requested ?? (child == nil && inherited == nil ? url.flatMap(FilePageOpener.tabEngine(for:)) : nil)
        let browserTabs = services.cache.browserTabs
        let route = BrowserTabRoute(isLocal: daemon.isLocal, connected: daemon.connection != nil,
                                    servesTabs: browserTabs.isAvailable(in: controller.pane))
        // Another machine that is not connected says so (cx-2cob).
        if route == .refuseNotConnected {
            child?.close()
            services.registry.refuse(RemoteStrings.browserMachineNotConnected(browserTabs.machineName(daemon)))
            return false
        }
        if route == .daemon {
            var choice: BrowserEngineChoice
            switch browserTabs.resolve(requested: requested, inherited: inherited, url: url) {
            case .refuse(let reason):
                services.registry.refuse(BrowserTabService.message(reason))
                return false
            case .open(let resolved): choice = resolved
            }
            if child != nil { choice = BrowserPageRequests.choice(adopting: child, inherited: inherited, browserTabs: browserTabs) }
            let pageRequests = services.cache.pageRequests
            let newTabAddress = services.newTabAddress(for: choice)
            let controller = controller, model = controller.pane
            // Home's pinned dock takes dragged tabs (`allow_tabs`, Leo 2026-10-21) but opens nothing in
            // itself (HomeDockOpens): a new browser tab aimed at it (History, Bookmarks, a URL from another
            // app, Split Browser, Duplicate Tab, a popup, the update card's Release Notes) is made there and
            // moves to a column on its right, as the daemon reroutes it for a dock closed to tabs. A caller's
            // `then` places it itself (LinkOpener, AgentBesidePlacement, a script's HomeDockOpens.placing).
            let beside = then == nil && controller.isOpenPinnedDockPane
            // Keep a Home-dock tab out of the dock strip until it lands beside the dock.
            let outbound = beside ? OutboundTab.begin(in: controller) : nil
            // A caller-supplied callback is HomeDockOpens.placing (or another placement owner).
            // It starts the move and owns the OutboundTab hold; selecting here after that callback
            // begins would release the hold and briefly restore Home's strip.
            let callerOwnsHomePlacement = controller.isOpenPinnedDockPane && placementOwner
            // A person's foreground tab: shown with its page in this turn (openStandIn). Not one aimed
            // at Home: the stand-in selects it in Home's dock, and its strip would come back (Lawrence
            // 2026-10-29: "chief in home should not have horizontal tabbar").
            if !beside, standInApplies(child: child, opener: opener, background: background,
                                        placementOwner: placementOwner) {
                openStandIn(choice, address: url?.absoluteString ?? newTabAddress, focusesAddressBar: url == nil,
                            profile: profile, notice: notice, then: then)
                return true
            }
            let linkOpener = services.linkOpener
            let intent = background || beside ? nil : controller.workspace?.beginFocusIntent()
            services.registry.track(Task {
                do {
                    // A new tab the user asked for opens the New Tab page; an
                    // adopted page (popup, extension tab) keeps its own.
                    let address = url?.absoluteString ?? (child == nil ? newTabAddress : BrowserNewTabPage.blankURL)
                    let surface = try await pageRequests.openers.open(opener, foreground: !background, in: model,
                                                                      browserTabs: browserTabs) { after in
                        try await browserTabs.open(choice, in: model, url: address, profile: profile, notice: notice,
                                                   activate: !background && !beside, after: after)
                    }
                    if let child { pageRequests.adopt(child, surface: surface) }
                    if beside {
                        linkOpener.moveBeside(surface, from: controller, focus: !background, target: url == nil ? .addressBar : .content,
                                              outbound: outbound)
                        return nil
                    }
                    then?(surface)
                    guard !background else { return nil }
                    if callerOwnsHomePlacement { return nil }
                    controller.selectWhenReported(surface: surface)
                    controller.workspace?.expectFocus(on: surface, target: url == nil ? .addressBar : .content, generation: intent)
                    return nil
                } catch {
                    outbound?.finish(moved: false)
                    if callerOwnsHomePlacement { OutboundTab.cancelLatest(in: controller) }
                    child?.close()
                    controller.daemon.logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                    return "new-frontend-browser-tab: \(error)"
                }
            })
            return true
        }
        guard BrowserTabRoute.allowsSessionLocalTab(url: url, requested: requested) else {
            child?.close()
            services.registry.refuse(RefusalStrings.needsDaemonCapability(DaemonCapability.frontendBrowserTabs.rawValue))
            return false
        }
        child?.close()  // Session-local tabs are WebKit pages made on demand.
        // Home's pinned dock holds no tab of this Mac's (H1): it opens in the pane right of the dock,
        // and with the dock alone, where no daemon move can take an app-only tab, it is refused.
        var holder = controller
        if controller.isPinnedDockPane {
            guard case .pane(let id) = services.linkOpener.target(from: controller), id != controller.layoutPaneID,
                  let right = controller.workspace?.panes[id] else {
                services.registry.refuse(RefusalStrings.needsDaemonCapability(DaemonCapability.frontendBrowserTabs.rawValue))
                return false
            }
            holder = right
        }
        let local = LocalBrowserTab.make(url: url)
        // Another machine's workspace: the tab is this Mac's; its page says so.
        if !holder.daemon.isLocal, !onMachine {
            browserTabs.setNotice(notice ?? {
                let name = browserTabs.machineName(holder.daemon)
                return RemoteStrings.browserRunsOnThisMac(name, route: .thisMacInstead(name, .webKit))
            }(), forKey: local.id)
        }
        holder.state?.localBrowserTabs[holder.paneKey].append(local)
        holder.apply(holder.snapshot())
        if background { return true }
        if holder !== controller, let content = holder.workspace { PaneHandlers.focus(holder.layoutPaneID, in: content) }
        holder.select(StripTabID(local.id))
        if url == nil { holder.workspace?.focus.send(.focusTarget(.addressBar, source: .intent)) }
        return true
    }
}

// MARK: Stand-in

extension PaneBrowserTabOpener {
    /// A person's foreground tab of this Mac's daemon in a normal window, with no popup page to
    /// adopt and no opener slot (decided after the reply).
    private func standInApplies(child: (any BrowserTab)?, opener: SurfaceID?, background: Bool,
                                 placementOwner: Bool) -> Bool {
        child == nil && opener == nil && !background && !placementOwner && controller.daemon.isLocal && controller.daemon.connection != nil
            && ActionRunScope.viewChangeAllowed() && !controller.services.cache.browserTabs.isIncognitoPane(controller.pane)
    }

    /// A new browser tab that waits for nothing (PL-cef-tab): the stand-in (`NewBrowserTabCommand`)
    /// is selected and shown with its page in the key's turn, so the tab and its themed content area
    /// draw in the key's frame and the page starts loading at once instead of after the daemon's
    /// reply. One path for every person's foreground tab `PaneBrowserTabOpener` sends to the daemon
    /// (New Browser Tab, the New Tab page's browser, a link in a new tab, New WebKit Tab). On the
    /// reply the stand-in's page and chrome move to the daemon's tab (`TabContentCache.moveBrowser`),
    /// which keeps its cell, selection and view. Keys typed meanwhile wait for the daemon's tab.
    private func openStandIn(_ choice: BrowserEngineChoice, address: String, focusesAddressBar: Bool, profile: String?, notice: String?, // perf-hot: 10ms new-tab (the stand-in shows in the key's turn)
                             then: (@MainActor (SurfaceID) -> Void)?) {
        let controller = controller, services = controller.services, cache = services.cache, model = controller.pane
        let command = NewBrowserTabCommand(pane: model.handle, url: address, engine: choice.engine.rawValue,
                                           profile: cache.browserTabs.resolveProfile(model, profile))
        let intent = controller.workspace?.beginFocusIntent(), window = controller.view.window
        let pending = BenchSpans.measure("browserTab.intend") {
            command.intendNow(on: controller.daemon) { try await cache.browserTabs.open(choice, in: model, url: address, profile: profile, notice: notice) }
        }
        let keys = services.keyRouter.creationInputCoordinator.begin(in: window, generation: intent, tab: pending.tab)
        controller.selectWhenReported(surface: pending.surface)
        services.registry.track(Task {
            var landed = false
            defer { services.keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window) }
            do {
                let surface = try await pending.send { surface in
                    if let tab = controller.daemon.store.tab(surface: surface) { _ = cache.moveBrowser(pending.tab, to: tab) }
                }
                let selected = controller.stripModel.selectedID?.rawValue
                if selected == nil || selected == pending.tab || controller.pendingSelectSurface == pending.surface { controller.selectWhenReported(surface: surface) }
                controller.workspace?.expectFocus(on: surface, target: focusesAddressBar ? .addressBar : .content, generation: intent)
                landed = true
                then?(surface)
                return nil
            } catch {
                cache.release(pending.tab)
                if error is NewBrowserTabCancelled { return nil }
                controller.daemon.logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }
}

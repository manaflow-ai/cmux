import AppKit
import CmuxNextBrowser
import CmuxNextLaunch
import CmuxNextPages
import CmuxNextWakeups

extension PaneContentView {
    /// Draws `image` (an agent page's last frame, `AgentPaneLaunchImages`)
    /// under the content, top-left at its point size, until the live page
    /// paints: an agent page is transparent until then, so the pane never
    /// shows empty at launch. While it shows in the window, `hold` holds startup open.
    ///
    /// `limit` is how long it may stay once the page it stands in for has painted
    /// (``LaunchImageHold/imageLimit``). It is not the bound on a page that never reports a first
    /// frame: such a page keeps its frame past it (`launchImageMayClear`), because taking it leaves
    /// the pane empty. What bounds that case is `AgentPaneLoadingView`'s give-up, which shows the
    /// page as it is after two unpainted checks (2 x `paintCheckInterval`, about 8 s). The startup
    /// hold's share still ends at `limit` either way, so deferred launch work never waits on it.
    func showLaunchImage(_ image: NSImage, hold: LaunchImageHold, limit: Duration = LaunchImageHold.imageLimit) {
        let view = NSView(frame: contentHost.bounds)
        view.wantsLayer = true
        view.layer?.contentsGravity = .topLeft
        view.layer?.contentsScale = image.recommendedLayerContentsScale(window?.backingScaleFactor ?? 2)
        view.layer?.contents = image.layerContents(forContentsScale: view.layer?.contentsScale ?? 2)
        putUpLaunchImage(view, positioned: .below, hold: hold, limit: limit)
        DebugTimings.markLaunch("agent_pane.launch_image_shown")
    }

    /// Draws a browser page's picture from the last quit (`BrowserLaunchPictures`) over the content, until its
    /// page shows its first content: a browser's toolbar and theme color would cover it from under. It takes no
    /// click (`BrowserLaunchPictureView`). While it shows in the window, `hold` holds startup open.
    func showLaunchPicture(_ view: BrowserLaunchPictureView, hold: LaunchImageHold) {
        view.frame = contentHost.bounds
        putUpLaunchImage(view, positioned: .above, hold: hold)
    }

    /// Puts `view` up as the pane's launch image, replacing the last one, until its limit.
    private func putUpLaunchImage(_ view: NSView, positioned place: NSWindow.OrderingMode, hold: LaunchImageHold,
                                  limit: Duration = LaunchImageHold.imageLimit) {
        // Before the old image goes, so a replaced image never ends the hold for a turn.
        let share = hold.began()
        clearLaunchImage()
        view.autoresizingMask = [.width, .height]
        contentHost.addSubview(view, positioned: place, relativeTo: nil)
        launchImageView = view
        launchImageShare = share
        launchImageDeadline.schedule(after: limit) { [weak self] in
            guard let self else { return }
            // The frame stands in for a page that has not drawn yet, so the limit alone does not
            // take it: dropping it here used to hand the pane its empty loading state while the
            // page was still inside its own first-paint budget, which is a chat that draws, goes
            // dark for several seconds, then comes back (Leo 2026-10-22). What takes it instead is
            // the page drawing over it, or the pane giving up on a page that never reports and
            // showing it as it is (`AgentPaneLoadingView`), both of which end on the page. The
            // give-up is still the earlier of the two budgets (about 8 s against the page's own
            // ~10 s `CHAT_DRAW_HOLD_MS` after its handshake), so a daemon slow enough to miss it
            // reveals the page while it is itself still blank. That narrows Leo's dark gap rather
            // than closing it; closing it means moving one of the two budgets.
            guard launchImageMayClear?() ?? true else {
                // The frame stays, but startup is not held past the limit for it.
                endLaunchImageShare(.visiblePaneTimedOut)
                return
            }
            clearLaunchImage(.visiblePaneTimedOut)
        }
    }

    /// A page's delayed reveal removes only the frame it stood behind. Another tab may have
    /// installed its own frame in this pane while that page was still loading.
    func clearLaunchImage(ifShowing image: NSView) {
        guard launchImageView === image else { return }
        clearLaunchImage()
    }

    /// Removes the launch image (the page painted, or the pane shows another tab).
    ///
    /// - Parameter reason: Why it goes, for the startup ref the last image ends.
    func clearLaunchImage(_ reason: StartupInProgressRef.Reason = .visiblePaneLoadedIdle) {
        launchImageDeadline.cancel()
        // The next frame says for itself whether its limit may take it; `putUpLaunchImage` clears
        // first, so a frame held over a painted page never inherits a relaunch's answer.
        launchImageMayClear = nil
        if let launchImageView {
            DebugTimings.markLaunch("agent_pane.launch_image_cleared")
            launchImageView.removeFromSuperview()
            self.launchImageView = nil
        }
        endLaunchImageShare(reason)
        // A page that has not painted when the image goes (its limit) shows its loading state.
        let cleared = onLaunchImageCleared
        onLaunchImageCleared = nil
        cleared?()
    }

    /// Ends the launch image's share of the startup hold; the image itself stays until it goes.
    func endLaunchImageShare(_ reason: StartupInProgressRef.Reason) {
        launchImageShare?.end(reason)
        launchImageShare = nil
    }
}

extension VisiblePaneRefs {
    /// The end of the launch restore (p08-startup task 013): the restore ref ends, and each visible pane
    /// holds startup until its content shows. What a pane shows, a window's visibility and a terminal's
    /// content are not observable: each reads the windows again (``noteChange()``).
    func finishRestore(of manager: WindowManager) {
        manager.services.cache.presentationChanges.subscribe("visible-pane-refs") { [weak self] in self?.noteChange() }
        followWindows(manager.controllers.compactMap(\.window))
        restoreFinished { [weak self, weak manager] in
            guard let self, let manager else { return [] }
            return windows(of: manager)
        }
    }

    /// Every launch window on screen, or kept off screen until its content is installed, with what it shows.
    /// A restored window that shows and waits for its launch build is one loading window.
    func windows(of manager: WindowManager) -> [Window] {
        _ = (manager.services.paneMounts.generation, manager.services.cache.pageInstalls.revision)
        let built = manager.controllers.compactMap { controller -> Window? in
            let id = controller.state.id
            guard manager.awaitingContent[id] != nil || Window.isOnScreen(controller.window) else { return nil }
            return Window(id: id, content: content(of: controller))
        }
        return built + (manager.launchWindows?.waitingVisible ?? []).map { Window(id: $0, content: .loading) }
    }

    /// The window's top page, else its shown workspace's panes on screen; nothing installed yet (the
    /// connecting view, a parked or mounting workspace) is `.loading`.
    private func content(of controller: WindowController) -> Window.Content {
        if let route = controller.shownTopPage, let view = controller.topPages.views[route] {
            // Classic Home is native: it shows whole at once.
            let state = (view as? InternalPageView).map { self.state(of: $0) } ?? .loadedIdle
            return .page(Pane(key: "window:\(controller.state.id):\(route)", state: state))
        }
        guard let content = controller.content, !content.isParked else { return .loading }
        return .workspace(onScreen: panesOnScreen(of: controller).map { Pane(key: $0.paneKey, state: state(of: $0)) },
                          layoutPanes: content.modelPanes.count)
    }

    /// The shown workspace's panes on screen. While the launch holds panes off screen, only the panes
    /// the layout reports on screen hold startup.
    private func panesOnScreen(of controller: WindowController) -> [PaneController] {
        guard let content = controller.content, !content.isParked else { return [] }
        let onlyVisible = controller.services.launchPanes.holdsPanes
        return content.panes.values.filter { Window.isOnScreen($0.view) && (!onlyVisible || $0.isVisible) }
    }

    /// The sessions of the live terminals on screen in the launch's windows, each pane's selected tab
    /// (`launch.visible_terminals_drawn`, ``LaunchTerminalsDrawn``). A window whose top page shows has none.
    func visibleTerminals(of manager: WindowManager) -> Set<ObjectIdentifier> {
        var sessions: Set<ObjectIdentifier> = []
        for controller in manager.controllers where Window.isOnScreen(controller.window) {
            guard controller.shownTopPage.flatMap({ controller.topPages.views[$0] }) == nil else { continue }
            for pane in panesOnScreen(of: controller) where pane.stripModel.selectedID != nil && pane.showsLiveTerminal {
                if case .terminal(let entry)? = pane.currentContent { sessions.insert(ObjectIdentifier(entry.session)) }
            }
        }
        return sessions
    }

    /// A pane's content signal: a terminal's first content, a page's first load ended, an agent or page
    /// tab's first paint (task 105 makes each loaded-idle). A placeholder, a notice and a conversation are
    /// native views with nothing left to load: they show whole when selected.
    func state(of pane: PaneController) -> PaneState {
        guard pane.stripModel.selectedID != nil else { return .loadedIdle }
        let loaded: Bool = switch pane.currentContent {
        case nil: false
        case .terminal(let entry)?: !pane.showsLiveTerminal || entry.session.hasContent
        case .browser(let entry)?: entry.tab is DeferredBrowserTab || entry.tab is HibernatedBrowserTab || entry.tab.state.launchLoadEnded
        case .agent(let view)?: view.model.hasPainted
        case .page(let view)?: state(of: view) == .loadedIdle
        case .placeholder?, .notice?, .conversation?: true
        }
        return loaded ? .loadedIdle : .loading
    }

    /// A page tab or a top page: loaded once its document painted (``PageWebView/hasPainted``), as its
    /// pane's paint hold waits for; the paint reads the panes again. Native content shows whole at once.
    func state(of page: InternalPageView) -> PaneState {
        guard let web = page.content as? PageWebView, !web.hasPainted else { return .loadedIdle }
        follow(web) { web.whenPainted($0) }
        return .loading
    }
}

extension BrowserTabState {
    /// A shown page's launch content signal: a load ended in it (finished, stopped or failed), or its
    /// process ended. A stand-in tab (deferred, hibernated) loads nothing and needs none.
    var launchLoadEnded: Bool { hasEndedLoad || processExit != nil }
}

/// One pane of the launch window as its build behind the picture shows it, focused pane first.
extension PaneController: LaunchWindowPane {
    /// The launch window's build behind its picture holds its content until its own slice (`showForLaunch`), so no
    /// turn builds every pane; the build ends when the phase is built.
    var launchHeld: Bool {
        guard !launchReleased, let phase = services.windows.launchPicture, !phase.isBuilt else { return false }
        return state?.id == services.windows.launchWindowID
    }

    func showForLaunch() {
        launchReleased = true
        services.presentation.cancel(self)
        showSelected()
    }

    /// The build ended before this pane's slice (another screen, scrolled away): it shows as usual now.
    func releaseFromLaunch() {
        guard !launchReleased else { return }
        launchReleased = true
        services.presentation.setNeedsShowSelected(self)
    }

    /// A terminal's first frame after its first content is applied; a page's first contentful paint, an agent's or
    /// internal page's first paint (each content's `createTabFirstFrame`); native content at its commit.
    func whenLaunchContentDrawn(_ drawn: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? {
        switch currentContent {
        case .terminal(let entry)? where showsLiveTerminal: return entry.session.whenContentFrameDrawn(drawn)
        case let content? where !content.isTerminal: return content.createTabFirstFrame.wait { _ in drawn() }
        default:
            drawn()
            return nil
        }
    }

    func launchArea(in picture: NSView) -> CGRect {
        view.window == nil || !isVisible ? .zero : view.convert(view.bounds, to: picture) // the layout's viewport presence
    }
}

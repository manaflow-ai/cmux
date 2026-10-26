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
    func showLaunchImage(_ image: NSImage, hold: LaunchImageHold) {
        // Before the old image goes, so a replaced image never ends the hold for a turn.
        let share = hold.began()
        clearLaunchImage()
        let view = NSView(frame: contentHost.bounds)
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.layer?.contentsGravity = .topLeft
        view.layer?.contentsScale = image.recommendedLayerContentsScale(window?.backingScaleFactor ?? 2)
        view.layer?.contents = image.layerContents(forContentsScale: view.layer?.contentsScale ?? 2)
        contentHost.addSubview(view, positioned: .below, relativeTo: nil)
        launchImageView = view
        launchImageShare = share
        DebugTimings.markLaunch("agent_pane.launch_image_shown")
        launchImageDeadline.scheduleOnMain(after: LaunchImageHold.imageLimit) { [weak self] in self?.clearLaunchImage(.visiblePaneTimedOut) }
    }

    /// Removes the launch image (the page painted, or the pane shows another tab).
    ///
    /// - Parameter reason: Why it goes, for the startup ref the last image ends.
    func clearLaunchImage(_ reason: StartupInProgressRef.Reason = .visiblePaneLoadedIdle) {
        launchImageDeadline.cancel()
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
    func windows(of manager: WindowManager) -> [Window] {
        _ = (manager.services.paneMounts.generation, manager.services.cache.pageInstalls.revision)
        return manager.controllers.compactMap { controller -> Window? in
            let id = controller.state.id
            guard manager.awaitingContent[id] != nil || Window.isOnScreen(controller.window) else { return nil }
            return Window(id: id, content: content(of: controller))
        }
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
        let onScreen = content.panes.values.filter { Window.isOnScreen($0.view) }
        return .workspace(onScreen: onScreen.map { Pane(key: $0.paneKey, state: state(of: $0)) }, layoutPanes: content.modelPanes.count)
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

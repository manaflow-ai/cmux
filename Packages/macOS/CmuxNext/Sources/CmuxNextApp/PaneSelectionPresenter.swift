import CmuxNextLaunch

/// Shows a pane's new selection so that no display frame mixes two tabs
/// (DOGFOOD-CALL L4). The strip's highlight and the content change in the
/// same pass, so they commit in one Core Animation transaction:
/// - content that is alive (a tab the user visited) is shown now;
/// - a first visit empties the pane now (its background, never the old
///   tab under the new highlight) and its surface is made on the next
///   frame within the one-new-surface budget, for whatever tab is
///   selected by then, so held Ctrl-Tab makes no surface for a tab it passed.
extension PaneController {
    func presentSelection() {
        guard !isSuspended else { return } // its workspace draws nothing: `resume` shows the selection
        guard !selectedContentIsAlive else {
            services.presentation.showNow(self)
            return
        }
        DebugTabSwitch.kind(self, "cold")
        if let key = currentTabKey {
            services.cache.withdraw(key, by: self)
            letGo(key, parks: true) // what showed stays parked here
        }
        if view.stripView.window != nil { view.stripView.syncFromModel() }
        if isFocusedInWorkspace, showsLiveTerminal {  // keys typed meanwhile wait for its surface
            services.keyRouter.creationInputCoordinator.holdUntilShown(in: view.window)
        }
        services.presentation.setNeedsShowSelected(self)
    }
}

/// The launch's hold on a pane's content (``LaunchPaneGate``, feature `launchVisiblePanesOnly`).
/// Until startup completes a pane the layout does not report on screen makes no
/// surface, page or engine; one in the keep-alive band makes it in an afterStartup post, one away
/// when it scrolls near (``setPresence(_:)``). On screen, the workspace's focused pane shows in the
/// turn the layout reports it and the other visible panes queue behind it, one new surface a frame,
/// as Chrome's `TabLoader` loads the active tab before the others (chrome/browser/sessions/tab_loader.cc).
extension PaneController {
    /// Shows the selection for presentation (the layout, a frame, a model change): while the launch window's
    /// build behind its picture holds this pane, its slice shows it (``launchHeld``); while the
    /// launch holds it off screen it makes nothing and waits for the end of startup instead. An action that
    /// needs the content calls ``showSelectionNow()``.
    func showSelected() {
        guard !launchHeld else { return }
        guard !holdsForLaunch else { return waitForLaunchEnd() }
        showSelectionNow()
    }

    /// True when showing the selection needs no new surface or page: it exists, or the launch holds
    /// it, so showing it makes nothing (``launchHeld``, ``holdsForLaunch``).
    var selectedContentIsAlive: Bool { selectedContentExists || launchHeld || holdsForLaunch }

    /// The selection's surface, page or view exists (or nothing is selected).
    var selectedContentExists: Bool {
        guard let key = stripModel.selectedID?.rawValue else { return true }
        return (key == currentTabKey && view.hostsContent) || services.cache.hasContent(for: key)
            || services.agentTabs.existingView(key) != nil || services.pages.existingView(key) != nil
    }

    /// The launch holds this pane's content: startup is not complete, the layout does not report the
    /// pane on screen, and the pane shows nothing yet whose selection has no content. A pane that
    /// shows content keeps it; a person's switch there makes its new tab when it shows.
    var holdsForLaunch: Bool {
        presence != .visible && currentTabKey == nil && !isSuspended && services.launchPanes.holdsPanes && !selectedContentExists
    }

    /// Showing the selection now makes its content while the launch holds panes (counted in
    /// ``LaunchPaneGate/viewsBuilt``).
    var buildsContentAtLaunch: Bool { services.launchPanes.holdsPanes && !selectedContentExists }

    /// The workspace's other visible panes show after its focused one while the launch holds panes.
    var showsAfterFocusedAtLaunch: Bool { services.launchPanes.holdsPanes && workspace?.focusedPane !== self }

    /// A held pane's one afterStartup post: then a pane in the keep-alive band makes its content, one
    /// away still waits for the layout to bring it near.
    func waitForLaunchEnd() {
        guard !waitsForLaunchEnd else { return }
        waitsForLaunchEnd = true
        services.launchPanes.afterStartup { [weak self] in self?.launchEnded() }
    }

    private func launchEnded() {
        waitsForLaunchEnd = false
        guard presence != .hidden, !isSuspended, currentTabKey == nil else { return }
        services.presentation.setNeedsShowSelected(self)
    }
}

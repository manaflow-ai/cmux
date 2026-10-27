import Foundation

/// A Chromium runtime update in host mode (task 087 of plans/cmux-next/chrome-parity/p01-process.md, feature
/// `chromiumHostRuntimeUpdate`): the running host keeps its runtime until an idle moment, then ends, and the next host
/// starts on the newer one with every page back from its saved history (the restore of task 083).
///
/// Chrome's component updates are used by the next process that starts, never by a running one (a new CDM version
/// serves the next CDM process, components/component_updater), and Chrome only discards a tab nobody sees and that
/// holds nothing a reload would lose (`CanDiscard`, chrome/browser/resource_coordinator/tab_lifecycle_unit.cc): no
/// page on screen, no audio, capture, connection, form input, beforeunload handler, open question or running download.
extension CEFRuntime {
    /// The supervisor has a newer runtime while a host runs on the older one: the host restarts on it once idle.
    func hostRuntimeChanged() {
        guard let update = hostStart?.runtimeUpdate, update.phase != .restarting else { return }
        update.phase = .waiting(blocker: nil)
        checkHostRuntimeUpdate()
    }

    /// A page was hidden: the moment a waiting update may restart the host (no page on screen any more).
    func hostPageConcealed() {
        guard case .waiting? = hostStart?.runtimeUpdate.phase else { return }
        checkHostRuntimeUpdate()
    }

    /// Checks now whether the waiting update can restart the host; one check at a time.
    func checkHostRuntimeUpdate() {
        guard let update = hostStart?.runtimeUpdate, case .waiting = update.phase, !update.checking else { return }
        if let retry = update.retry { _ = waitDeadlines.cancel(retry) }
        update.retry = nil
        update.checking = true
        Self.check(self)
    }

    /// The check waits off the main actor, as a sad tab's restart does (``reloadAfterHostRestart(_:)``): the probes and
    /// the restart each run on main as the runtime's own calls.
    private nonisolated static func check(_ runtime: CEFRuntime) {
        // task-owner: one check per update, retry or hidden page at a time; it ends with its page probes, and quit ends
        // the update (state)
        Task { [weak runtime] in await runtime?.restartHostIfIdle() }
    }

    private func restartHostIfIdle() async {
        guard let hostStart else { return }
        let update = hostStart.runtimeUpdate
        defer { update.checking = false }
        guard case .waiting = update.phase else { return }
        guard state == .ready, shutdownSequence == nil else {
            // No host runs (or quit began): the next host starts on the newer runtime by itself.
            update.phase = .none
            return
        }
        if let blocker = await hostRestartBlocker(update) {
            guard case .waiting = update.phase else { return }
            update.phase = .waiting(blocker: blocker)
            update.retry = waitDeadlines.schedule(owner: "CEFRuntime.hostRuntimeUpdate", after: CEFHostRuntimeUpdate.retryAfter,
                                                  placement: .flexible) { [weak self] in
                self?.hostStart?.runtimeUpdate.retry = nil
                self?.checkHostRuntimeUpdate()
            }
            return
        }
        guard case .waiting = update.phase, state == .ready, shutdownSequence == nil else { return }
        update.phase = .restarting
        await restartHostOnNewerRuntime(hostStart)
        update.phase = .none
        update.restarts += 1
    }

    /// Why the running host must stay now, nil when it may restart.
    private func hostRestartBlocker(_ update: CEFHostRuntimeUpdate) async -> String? {
        if let blocker = runtimeRestartBlocker() { return blocker }
        for tab in tabsByBrowser.values where !tab.isClosed {
            if let blocker = await update.pageBlocker(tab) { return blocker }
        }
        // A page may have shown, or begun a question, while the pages answered.
        return runtimeRestartBlocker()
    }

    /// What keeps the host that the runtime knows without asking a page.
    private func runtimeRestartBlocker() -> String? {
        if downloads.hasRunning { return "a download runs" }
        for tab in hosts.values.flatMap(\.tabs) where !tab.isClosed {
            if tab.isShownInVisibleWindow { return "a page is on screen" }
            if tab.isAudible { return "a page plays audio" }
            if !tab.pendingPrompts.isEmpty { return "a page asks a question" }
            if tab.restored.showsFormSubmission { return "a page shows a form's result" }
            if tab.isCreationPending || tab.hasHostRestore { return "a page is being made" }
        }
        return nil
    }

    /// Ends the idle host and brings every page back on the next one, which the supervisor starts on its newest
    /// runtime. The pages are hidden, so none shows a crash page: each comes back with its saved navigation, a hidden
    /// one when it shows, as after a crash within the restart budget. The next host starts only once the old one is
    /// gone: both would use the same data folder.
    private func restartHostOnNewerRuntime(_ hostStart: CEFHostStart) async {
        logger.notice("chromium host restarts on a newer runtime tabs=\(self.tabsByBrowser.count)")
        let tabs = forgetHost(hostStart)
        for tab in tabs { tab.leftHostForRuntimeUpdate() }
        spareWindow.hostEnded(runtime: self)
        await hostStart.endHost(within: CEFShutdownSequence.hostEndLimit)
        // Quit began while the old host ended: quit's own end covers the pages.
        guard state == .idle else { return }
        restorePagesOnNextHost(tabs, reading: hostStart.savedNavigation)
    }
}

extension CEFTab {
    /// What this page says keeps its host from a planned restart, from its recorder's probe (``BrowserPageBusy``); nil
    /// when nothing does. A page that does not answer keeps nothing, as Chrome's discard assumes no form interaction
    /// it was not told of.
    func hostRestartBlocker() async -> String? {
        guard let busy = try? await pageBusy() else { return nil }
        if busy.capturing { return "a page captures" }
        if busy.audio { return "a page plays audio" }
        if busy.webRTC || busy.connectedDevice { return "a page holds a connection" }
        if busy.editedForm == true { return "a page has form input" }
        if busy.beforeUnload || busy.unloadHandler { return "a page has a beforeunload handler" }
        return nil
    }

    /// The host restarts on a newer runtime (task 087) while this page is hidden: its browser goes with the host, with
    /// no crash page; the restore brings it back on the next host.
    func leftHostForRuntimeUpdate() {
        (browserID, isCreationPending) = (nil, false)
        agentRelay.browserEnded()
        dismissPrompts()
    }
}

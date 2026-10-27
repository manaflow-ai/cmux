import Foundation

/// The Chromium Host's end while Chromium runs in it (``BrowserBackend/host``, p08-startup-046).
extension CEFRuntime {
    /// The host ended: every page it showed shows `exit`'s crash state (the sad tab), every reply still
    /// awaited fails with `hostGone`, and the crash log records the host once. Only the host's process
    /// ended: cmux keeps running, as Chrome's browser does when a child process dies
    /// (content/browser/renderer_host/render_process_host_impl.cc, `ProcessDied`).
    ///
    /// Every browser, window and context went with the host, so the runtime leaves `.ready` and forgets
    /// them: the remote shim gives up the dead wire, nothing is sent until a new host is attached, and the
    /// next start (a new tab, or a page's Reload through ``reloadAfterHostRestart(_:)``) asks the
    /// supervisor for a host again, as Chrome's `BrowserGpuChannelHostFactory` establishes a new channel
    /// after the GPU process died. Restoring each tab's history on the new host is task 083 of
    /// plans/cmux-next/chrome-parity/p01-process.md. No effect in process, before Chromium runs, or
    /// while quitting (quit ends the host).
    func hostEnded(_ exit: BrowserProcessExit) {
        guard let hostStart, state == .ready, shutdownSequence == nil else { return }
        logger.error("chromium host ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tabs=\(self.tabsByBrowser.count)")
        crashLog.append(BrowserCrashRecord(processType: "chromium-host", reason: exit.reason, code: exit.code, source: .process))
        // Every awaited reply fails with hostGone; each proxied profile's proxy goes to the next host again.
        hostGone()
        hostStart.hostEnded()
        shim = nil
        state = .idle
        // The pages on the host: its browsers, and the tabs whose browser it was still making.
        let tabs = Array(tabsByBrowser.values) + hosts.values.flatMap(\.tabs).filter { $0.browserID == nil && $0.isCreationPending }
        (tabsByBrowser, pendingWindows, tabBeingAdded) = ([:], [:], nil)
        (orphans.ledger, orphans.unplaced) = (CEFAdoptionLedger(), [:])
        // The new host has none of the old one's contexts.
        offTheRecordContexts = [:]
        for host in hosts.values { host.hostEnded() }
        for tab in tabs { tab.hostEnded(exit) }
        // The spares' placeholders went with the host (their tabs forgot their browsers above).
        spareWindow.hostEnded(runtime: self)
    }

    /// The host ended and no new one is attached yet (``hostEnded(_:)``): a page's Reload waits for one.
    var awaitsHostRestart: Bool { hostStart?.hostGone == true }

    /// Reloads `tab` once a new host is attached: starts the runtime again (the supervisor starts a
    /// host), then reloads it on that host, where a shown tab gets a new browser at once and a hidden
    /// one when it shows. Nothing reaches the dead host's wire. A host that cannot start leaves the
    /// sad tab.
    func reloadAfterHostRestart(_ tab: CEFTab) {
        Self.restartHost(self, thenReload: tab)
    }

    /// The restart waits off the main actor: the start and the reload each run on main as the runtime's own
    /// calls, and the main thread holds nothing while the supervisor starts the host.
    private nonisolated static func restartHost(_ runtime: CEFRuntime, thenReload tab: CEFTab) {
        // task-owner: one per Reload of a sad tab; the shared attach (CEFHostStart) owns the restart, and quit fails it
        Task { [weak runtime, weak tab] in
            guard let runtime else { return }
            do { try await runtime.start(layout: nil, trigger: "hostRestart") } catch { return }
            guard let tab else { return }
            await runtime.reloadOnRestartedHost(tab)
        }
    }

    /// The new host is attached: `tab` loads its page there, and gets a browser now when it is shown.
    private func reloadOnRestartedHost(_ tab: CEFTab) {
        guard !tab.isClosed, !awaitsHostRestart else { return }
        tab.reload()
        tab.host.recreateShown(tab)
    }

    /// Puts a runtime that has not started in host mode (``adopt(stores:signInCallbacks:waitDeadlines:hostSupervisor:hostWidgets:hostDrags:hostDragOut:hostResizeFence:hostPopupMenus:hostSuggestions:hostFileDialogs:)``):
    /// its start attaches through `supervisor` (host widgets in cmux with `showsWidgets`, drops with `takesDrags`, its
    /// pages' drags when `dragsOut`, page resizes fenced with `fencesResizes`, `<select>` popups as cmux menus with
    /// `drawsPopupMenus`, suggestions in cmux's list with `drawsSuggestions`, page file choosers answered by
    /// `fileDialogs`), and the host's ends reach ``hostEnded(_:)`` when the supervisor reports them
    /// (``ChromiumHostExitReporting``).
    func adoptHost(_ supervisor: any ChromiumHostSupervising, showsWidgets: Bool = false, takesDrags: Bool = false,
                   dragsOut: Bool = false, fencesResizes: Bool = false, drawsPopupMenus: Bool = false,
                   drawsSuggestions: Bool = false, fileDialogs: (any ChromiumFileDialogAnswering)? = nil) {
        hostStart = CEFHostStart(supervisor: supervisor, showsWidgets: showsWidgets, takesDrags: takesDrags, dragsOut: dragsOut,
                                 fencesResizes: fencesResizes, drawsPopupMenus: drawsPopupMenus, fileDialogs: fileDialogs)
        hostStart?.drawsSuggestions = drawsSuggestions
        guard let reporting = supervisor as? any ChromiumHostExitReporting else { return }
        reporting.onHostEnded = { [weak self] exit in self?.hostEnded(exit) }
    }
}

extension CEFPaneHost {
    /// The Chromium Host ended (``CEFRuntime/hostEnded(_:)``): this pane's Chromium window went with it, so the
    /// next tab shown here asks the next host for a new one, and the page view drops all the host gave it in
    /// this turn, under each tab's sad tab (``CEFTab/hostEnded(_:)``). The next host numbers browsers anew.
    func hostEnded() {
        (window, windowTab, lastActivated, popupWindow, pageCursors) = (.none, nil, nil, nil, [:])
        hostView.layerHosting.windowBrowsersChanged([])
        hostedPageView?.hostEnded()
    }

    /// After a new host was attached, `tab`, shown here with no browser (its own went with the old
    /// host), gets one from the new host, as ``present(_:in:)`` makes a new tab's.
    func recreateShown(_ tab: CEFTab) {
        guard visibleTab === tab, tab.browserID == nil, !tab.awaitsWindowMove else { return }
        if ensureCreated(tab) { showBrowser(of: tab, activate: false) }
    }
}

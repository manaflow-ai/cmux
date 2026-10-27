import Foundation

/// The Chromium Host's end while Chromium runs in it (``BrowserBackend/host``, p08-startup-046).
extension CEFRuntime {
    /// The host ended: every page it showed shows `exit`'s crash state (the sad tab), everything still
    /// awaited from it resolves (``hostGone()``), and the crash log records the host once. Only the host's process
    /// ended: cmux keeps running, as Chrome's browser does when a child process dies
    /// (content/browser/renderer_host/render_process_host_impl.cc, `ProcessDied`).
    ///
    /// Every browser, window and context went with the host, so the runtime leaves `.ready` and forgets
    /// them: the remote shim gives up the dead wire, nothing is sent until a new host is attached, and the
    /// next start (a new tab, or a page's Reload through ``reloadAfterHostRestart(_:)``) asks the
    /// supervisor for a host again, as Chrome's `BrowserGpuChannelHostFactory` establishes a new channel
    /// after the GPU process died. Restoring each tab's history on the new host is task 083 of
    /// plans/cmux-next/chrome-parity/p01-process.md. No effect in process; before Chromium runs or while
    /// quitting (quit ends the host) only the waits resolve.
    func hostEnded(_ exit: BrowserProcessExit) {
        guard let hostStart, state == .ready, shutdownSequence == nil else { return hostGone() }
        logger.error("chromium host ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tabs=\(self.tabsByBrowser.count)")
        crashLog.append(BrowserCrashRecord(processType: "chromium-host", reason: exit.reason, code: exit.code, source: .process))
        // The dead wire goes first, as mojo marks its endpoint errored before it runs the pending
        // callbacks: an answer below that asks the host again finds none (unsent), not a token
        // that waits for its deadline.
        hostStart.hostEnded()
        shim = nil
        state = .idle
        // While each tab still has its browser: a person's close whose answer cannot come closes its tab.
        hostGone()
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

    /// The host's wire ended, whatever ended it (a crash, a kill, a quit, a clean or idle exit; task 091
    /// of plans/cmux-next/chrome-parity/p01-process.md): in this turn, everything that waited on that host
    /// resolves and every sheet cmux showed for it closes, as a mojo disconnect runs each pending reply
    /// callback with its default and then the disconnect handler
    /// (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc, `NotifyError`):
    /// - every REPLY token (async ops, `<select>` answers, page contexts) fails with
    ///   ``CEFHostReplyError/hostGone``, and the host's widgets, `<select>` menu and file pickers close
    ///   (``CEFHostStart/hostDisconnected()``);
    /// - the waits answered by the host's events (evaluations, DevTools calls, site replies, extension
    ///   omnibox suggestions) fail as their browser's close fails them: every browser was the host's;
    /// - each pane's autofill and password suggestions close, and each of the host's pages gets the
    ///   dismissal answer of its open questions (beforeunload, permissions, passwords, external apps);
    /// - every profile proxy is handed to the next host again before a page of its profile opens: a
    ///   host's verdict on a proxy says nothing about the host after it, whose Chromium context starts
    ///   without the proxy (#24432 fails closed).
    ///
    /// The supervisor's ``ChromiumHostSupervising/observeHostEnds(_:)`` runs it for every end (and the
    /// host start's own part alone for a start no runtime adopted), and ``hostEnded(_:)`` for the ends
    /// pages show; a second call finds nothing. No effect in process.
    func hostGone() {
        guard let hostStart else { return }
        hostStart.hostDisconnected()
        devToolsCalls.failAll(where: { _ in true }, with: BrowserTabError.closed)
        siteReplies.failAll(where: { _ in true }, with: BrowserTabError.closed)
        latestEvaluation.take()?.done(nil)
        evaluations.failAll(where: { _ in true }, with: BrowserTabError.closed)
        omniboxKeywords.hostEnded()
        for host in hosts.values { host.hostedPageView?.suggestions.hostEnded() }
        for tab in tabsByBrowser.values { tab.dismissPrompts() }
        profileProxyChecks.removeAll()
        unappliedProfileProxies.formUnion(profileProxies.keys)
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

    /// Puts a runtime that has not started in host mode (``adopt(stores:signInCallbacks:waitDeadlines:hostSupervisor:hostWidgets:hostDrags:hostResizeFence:hostPopupMenus:hostSuggestions:hostFileDialogs:)``):
    /// its start attaches through `supervisor` (host widgets in cmux with `showsWidgets`, drops with `takesDrags`, page
    /// resizes fenced with `fencesResizes`, `<select>` popups as cmux menus with `drawsPopupMenus`, suggestions in cmux's
    /// list with `drawsSuggestions`, page file choosers answered by `fileDialogs`), and the host's ends reach
    /// ``hostEnded(_:)`` when the supervisor reports them (``ChromiumHostExitReporting``).
    func adoptHost(_ supervisor: any ChromiumHostSupervising, showsWidgets: Bool = false, takesDrags: Bool = false,
                   fencesResizes: Bool = false, drawsPopupMenus: Bool = false, drawsSuggestions: Bool = false,
                   fileDialogs: (any ChromiumFileDialogAnswering)? = nil) {
        hostStart = CEFHostStart(supervisor: supervisor, showsWidgets: showsWidgets, takesDrags: takesDrags,
                                 fencesResizes: fencesResizes, drawsPopupMenus: drawsPopupMenus, fileDialogs: fileDialogs)
        hostStart?.drawsSuggestions = drawsSuggestions
        supervisor.observeHostEnds { [weak self] in self?.hostGone() }
        guard let reporting = supervisor as? any ChromiumHostExitReporting else { return }
        reporting.onHostEnded = { [weak self] exit in self?.hostEnded(exit) }
    }
}

extension CEFPaneHost {
    /// The Chromium Host ended (``CEFRuntime/hostEnded(_:)``): this pane's Chromium window went with
    /// it, so the next tab shown here asks the next host for a new one.
    func hostEnded() {
        (window, windowTab, lastActivated, popupWindow) = (.none, nil, nil, nil)
        hostView.layerHosting.windowBrowsersChanged([])
        hostedPageView?.show(contextID: 0)
    }

    /// After a new host was attached, `tab`, shown here with no browser (its own went with the old
    /// host), gets one from the new host, as ``present(_:in:)`` makes a new tab's.
    func recreateShown(_ tab: CEFTab) {
        guard visibleTab === tab, tab.browserID == nil, !tab.awaitsWindowMove else { return }
        if ensureCreated(tab) { showBrowser(of: tab, activate: false) }
    }
}

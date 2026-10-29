import CmuxNextWakeups
import Foundation

/// The Chromium Host's end while Chromium runs in it (``BrowserBackend/host``).
extension CEFRuntime {
    /// The host ended: everything still awaited from it resolves (``hostWireEnded()``), every page it showed
    /// shows `exit`'s crash state (the sad tab), and the crash log records the host once. Only the host's process
    /// ended: cmux keeps running, as Chrome's browser does when a child process dies
    /// (content/browser/renderer_host/render_process_host_impl.cc, `ProcessDied`).
    ///
    /// Every browser, window and context went with the host, so the runtime leaves `.ready` and forgets
    /// them: the remote shim gives up the dead wire, nothing is sent until a new host is attached, and the
    /// next start (a new tab, or a page's Reload through ``reloadAfterHostRestart(_:)``) asks the
    /// supervisor for a host again, as Chrome's `BrowserGpuChannelHostFactory` establishes a new channel
    /// after the GPU process died. With `restoresPages` (the supervisor's restart budget had room for this
    /// end) that start comes now and every page comes back on the new host with the navigation
    /// `savedNavigation` reads for it (``restorePagesOnNextHost(_:reading:)``, task 083 of
    /// plans/cmux-next/chrome-parity/p01-process.md). The pages show the end once, whether the supervisor's
    /// observers ran ``hostWireEnded()`` before this or not. No effect in process; before Chromium runs or while
    /// quitting (quit ends the host) only the waits resolve.
    func hostEnded(_ exit: BrowserProcessExit, restoresPages: Bool = false, savedNavigation: ChromiumHostSavedNavigation? = nil) {
        hostWireEnded()
        guard let hostStart, hostStart.pagesAwaitEnd else { return }
        hostStart.pagesAwaitEnd = false
        logger.error("chromium host ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tabs=\(self.tabsByBrowser.count)")
        crashLog.append(BrowserCrashRecord(processType: "chromium-host", reason: exit.reason, code: exit.code, source: .process))
        // The pages on the host: its browsers, the tabs whose browser it was still making, and those a restore brings to it.
        let restores = hostStart.pageRestores
        let tabs = Array(tabsByBrowser.values) + hosts.values.flatMap(\.tabs).filter {
            $0.browserID == nil && ($0.isCreationPending || restores.phase(of: $0) != nil)
        }
        (tabsByBrowser, pendingWindows, tabBeingAdded) = ([:], [:], nil)
        (orphans.ledger, orphans.unplaced) = (CEFAdoptionLedger(), [:])
        // The new host has none of the old one's contexts.
        offTheRecordContexts = [:]
        for host in hosts.values { host.hostEnded() }
        for tab in tabs { tab.hostEnded(exit) }
        // The spares' placeholders went with the host (their tabs forgot their browsers above).
        spareWindow.hostEnded(runtime: self)
        if restoresPages { restorePagesOnNextHost(tabs, reading: savedNavigation) } else { restores.endAll() }
    }

    /// The host's wire ended, whatever ended it and whatever reports it first (the supervisor's
    /// ``ChromiumHostSupervising/observeHostEnds(_:)``, its ``ChromiumHostExitReporting/onHostEnded``, or
    /// the wire's own end, ``CEFHostReplies/wireEnded()``; task 091 of
    /// plans/cmux-next/chrome-parity/p01-process.md). As a mojo disconnect marks the endpoint errored
    /// before it runs the pending reply callbacks (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc,
    /// `NotifyError`), a runtime Chromium ran on gives up the dead wire first and leaves `.ready`: an
    /// answer that asks the host again finds no wire (unsent), and the next start asks the supervisor
    /// for a host. Then everything that waited on the host resolves (``hostGone()``). The pages show the
    /// end's crash state when ``hostEnded(_:)`` brings the exit. A second call finds nothing.
    func hostWireEnded() {
        if let hostStart, state == .ready, shutdownSequence == nil {
            hostStart.hostEnded()
            hostStart.pagesAwaitEnd = true
            publishHelperParent()  // none until the next host is attached
            shim = nil
            state = .idle
        }
        hostGone()
    }

    /// What the host's end resolves, in its turn (``hostWireEnded()`` runs it once the wire is gone), as
    /// a mojo disconnect runs each pending reply callback with its default and then the disconnect handler:
    /// - each of the host's pages gets the dismissal answer of its open questions (beforeunload,
    ///   permissions, passwords, external apps), and extension prompts close with no answer;
    /// - every REPLY token (async ops, `<select>` answers, page contexts) fails with
    ///   ``CEFHostReplyError/hostGone``, and the host's widgets, `<select>` menu and file pickers close
    ///   (``CEFHostStart/hostDisconnected()``): a person's close no answer can come for closes its tab;
    /// - the waits answered by the host's events (evaluations, DevTools calls, site replies, extension
    ///   omnibox suggestions) fail as their browser's close fails them: every browser was the host's;
    /// - each pane's autofill and password suggestions close;
    /// - every profile proxy is handed to the next host again before a page of its profile opens: a
    ///   host's verdict on a proxy says nothing about the host after it, whose Chromium context starts
    ///   without the proxy (#24432 fails closed).
    ///
    /// A second call finds nothing. No effect in process.
    func hostGone() {
        guard let hostStart else { return }
        // The questions first: a page's close that waits on its beforeunload goes on without it.
        for tab in tabsByBrowser.values { tab.dismissPrompts() }
        extensionPrompts.hostEnded()
        hostStart.hostDisconnected()
        devToolsCalls.failAll(where: { _ in true }, with: BrowserTabError.closed)
        siteReplies.failAll(where: { _ in true }, with: BrowserTabError.closed)
        latestEvaluation.take()?.done(nil)
        evaluations.failAll(where: { _ in true }, with: BrowserTabError.closed)
        omniboxKeywords.hostEnded()
        for host in hosts.values { host.hostedPageView?.suggestions.hostEnded() }
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
        Self.restartHost(self, then: tab, reloads: true)
    }

    /// `tab` was sent to a new address while its host restore waited for the next host (``CEFTab/hostRestoreNavigated()``):
    /// once that host is attached, a shown `tab` gets its browser there with that address, a hidden one when it shows.
    func createAfterHostRestart(_ tab: CEFTab) {
        Self.restartHost(self, then: tab, reloads: false)
    }

    /// The restart waits off the main actor: the start and the reload each run on main as the runtime's own
    /// calls, and the main thread holds nothing while the supervisor starts the host.
    private nonisolated static func restartHost(_ runtime: CEFRuntime, then tab: CEFTab, reloads: Bool) {
        // task-owner: one per Reload of a sad tab, or per navigation of a page a host restore waited for; the shared
        // attach (CEFHostStart) owns the restart, and quit fails it
        Task { [weak runtime, weak tab] in
            guard let runtime else { return }
            do { try await runtime.start(layout: nil, trigger: "hostRestart") } catch { return }
            guard let tab else { return }
            await runtime.resumeOnRestartedHost(tab, reloads: reloads)
        }
    }

    /// The new host is attached: `tab` loads its page there (again when `reloads`), and gets a browser now when it is
    /// shown. A page a restore brings back (``restorePagesOnNextHost(_:reading:)``) comes back that way, with its history.
    private func resumeOnRestartedHost(_ tab: CEFTab, reloads: Bool) {
        guard !tab.isClosed, !awaitsHostRestart, hostStart?.pageRestores.phase(of: tab) == nil else { return }
        if reloads { tab.reload() }
        tab.host.recreateShown(tab)
    }

    /// Puts a runtime that has not started in host mode (``adopt(stores:signInCallbacks:waitDeadlines:hostSupervisor:hostWidgets:hostInput:hostDrags:hostResizeFence:hostPopupMenus:hostSuggestions:hostChoosers:hostFileDialogs:hostLocks:hostAppEvents:helperParent:pageHostScripts:)``):
    /// its start attaches through `supervisor` (host widgets in cmux with `showsWidgets`, hosted pages' input through
    /// the host's input ring with `routesInput`, drops with `takesDrags`, page
    /// resizes fenced with `fencesResizes`, `<select>` popups as cmux menus with `drawsPopupMenus`, suggestions in cmux's
    /// list with `drawsSuggestions`, choosers in cmux with `drawsChoosers`, page file choosers answered by `fileDialogs`); every end of the host reaches
    /// ``hostWireEnded()`` through the start, and ``hostEnded(_:)`` when the supervisor reports it (``ChromiumHostExitReporting``).
    func adoptHost(_ supervisor: any ChromiumHostSupervising, showsWidgets: Bool = false, routesInput: Bool = false,
                   takesDrags: Bool = false, fencesResizes: Bool = false, drawsPopupMenus: Bool = false,
                   drawsSuggestions: Bool = false, drawsChoosers: Bool = false,
                   fileDialogs: (any ChromiumFileDialogAnswering)? = nil, handlesLocks: Bool = false,
                   appEvents: AppEvents? = nil) {
        hostStart = CEFHostStart(supervisor: supervisor, showsWidgets: showsWidgets, routesInput: routesInput,
                                 takesDrags: takesDrags, fencesResizes: fencesResizes, drawsPopupMenus: drawsPopupMenus,
                                 fileDialogs: fileDialogs)
        hostStart?.drawsSuggestions = drawsSuggestions
        hostStart?.drawsChoosers = drawsChoosers
        hostStart?.locks = handlesLocks ? CEFHostLocks(runtime: self, appEvents: appEvents) : nil
        guard let reporting = supervisor as? any ChromiumHostExitReporting else { return }
        reporting.onHostEnded = { [weak self, weak reporting] exit in
            self?.hostEnded(exit, restoresPages: reporting?.lastEndRestoresPages == true, savedNavigation: reporting?.savedNavigation)
        }
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

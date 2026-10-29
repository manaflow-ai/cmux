public import CmuxNextWakeups
public import Foundation

extension CEFRuntime {
    /// The process whose children are the Chromium helpers that render this runtime's tabs: the app in process,
    /// the attached Chromium Host in host mode, nil in host mode while no host is attached.
    /// ``ChromiumHelperProcess/list(parent:)`` lists them; the tabs' renderer client ids match their
    /// `--renderer-client-id` in either mode.
    var helperParentPID: pid_t? {
        guard let hostStart else { return getpid() }
        return hostStart.hostPID
    }

    /// Writes ``helperParentPID`` where listings off the main actor read it (``helperParent``): when the runtime
    /// enters host mode, attaches a host, loses it, and adopts a source.
    func publishHelperParent() {
        helperParent.set(helperParentPID)
    }
}

extension ChromiumEngineSlot {
    /// Whose children the Chromium helpers are now (``CEFRuntimeSource/helperParent``): the app's, or the Chromium
    /// Host's in host mode, nil while no host is attached. Off the main actor, read `source.helperParent`.
    public var helperParent: pid_t? { source.helperParent.pid }
}

extension CEFTab: BrowserProcessReporting, BrowserSubframeCrashReporting {
    /// Renderer client ids hosting this tab's frames (main frame, out-of-process iframes; one per site). In host
    /// mode they are the host's mirror (`tab.renderer_client_ids`), which it pushes at each event that changes them.
    public var contentProcesses: BrowserContentProcesses {
        guard let browserID, let shim = runtime.shim else { return .none }
        let ids = shim.rendererClientIDs(browserID, 32)
        guard !ids.isEmpty else { return .none }
        return .chromiumRendererClients(ids)
    }

    /// The pid of the renderer that hosts this tab's main frame (the fork's
    /// `cmux_cef_browser_renderer_pid`); same-site tabs can share it. Nil before the
    /// browser exists, while it has no renderer, on a fork without the call and in host mode.
    public var rendererPID: pid_t? {
        guard let browserID, let shim = runtime.shim else { return nil }
        let pid = shim.rendererPID(browserID)
        return pid > 0 ? pid : nil
    }

    /// What this tab, as tab `id`, reports about its renderers: its main frame's renderer
    /// pid and the renderer client ids of all its frames. Two shim calls, no system call.
    public func renderers(tab id: String) -> ProcessUsage.TabRenderers {
        let clients: [Int32] = if case .chromiumRendererClients(let ids) = contentProcesses { ids } else { [] }
        return ProcessUsage.TabRenderers(tab: id, title: state.title ?? "", pid: rendererPID, rendererClients: clients)
    }

    /// Publishes this tab's ``renderers(tab:)`` as tab `id` into `directory` now, and again whenever they may
    /// change (``onRenderersMayChange``) while `isCurrent` says `id` still names this page: one tab per
    /// change, so the busy watchdog reads every tab's renderers off the main thread.
    public func publishRenderers(as id: String, into directory: TabRendererDirectory, while isCurrent: @escaping (CEFTab) -> Bool) {
        directory.update(renderers(tab: id))
        onRenderersMayChange = { [weak self] in
            guard let self, isCurrent(self) else { return }
            directory.update(self.renderers(tab: id))
        }
    }

    /// The renderer ended (crash, kill, out of memory, launch failure). The
    /// pane shows the sad tab, now or when the tab is next shown; only its
    /// Reload button (or the person's own reload) loads the page again. Chromium
    /// reported it, so the crash log records a renderer.
    func rendererTerminated(_ exit: BrowserProcessExit) {
        contentFullscreenEnded()
        guard showProcessExit(exit) else { return }
        runtime.recordRendererExit(exit, tab: self)
    }

    /// Renderer `pid`, which hosted a frame of this page (``CEFChildProcessMonitor/Exit/subframeBrowsers``), ended
    /// abnormally. When it is not the page's main frame renderer (whose end is ``rendererTerminated(_:)``, the sad tab),
    /// a subframe crashed: ``onSubframeCrash`` runs. Chrome reads the same from the frame nodes of the dead process
    /// (chrome/browser/performance_manager/policies/discard_page_with_crashed_subframe_policy.cc).
    func subframeRendererEnded(pid: pid_t) {
        guard let hook = onSubframeCrash, let main = rendererPID,
              Self.isSubframeCrash(main: main, ended: pid, pageExited: state.processExit != nil, closed: isClosed) else { return }
        hook()
    }

    /// Whether a renderer `ended` that hosted a frame of a page is a subframe's crash: the page is open, its
    /// own renderer, `main`, is another process, and Chromium did not report the page's own end.
    nonisolated static func isSubframeCrash(main: pid_t, ended: pid_t, pageExited: Bool, closed: Bool) -> Bool {
        !closed && !pageExited && main > 0 && main != ended
    }

    /// The Chromium Host ended with this page's browser in it (`CEFRuntime.hostEnded`): the sad tab
    /// as for a renderer's end, and the browser is gone, so the page waits for a new one from the
    /// next host (``reload()`` re-attaches first). The runtime records the host's end once; no
    /// renderer record, since Chromium reported none.
    func hostEnded(_ exit: BrowserProcessExit) {
        // Unlike `browserDidClose`, the tab stays: its agent session and open questions end, and its
        // page waits stay for the page the next host loads.
        (browserID, isCreationPending) = (nil, false)
        agentRelay.browserEnded()
        dismissPrompts()
        contentFullscreenEnded()
        showProcessExit(exit)
    }

    /// The page left HTML fullscreen without a FULLSCREEN a = 0 (its renderer, browser or host ended):
    /// the toolbar shows again and, in host mode with cmux's locks, its pane's fullscreen zoom ends
    /// (``BrowserTabIntent/contentFullscreen(_:)``), as Chrome exits tab fullscreen when the tab's
    /// renderer dies or the tab closes (`WebContentsImpl::RenderViewTerminated`, `ExitFullscreen`).
    func contentFullscreenEnded() {
        guard state.isContentFullscreen else { return }
        machine.apply(.contentFullscreenChanged(false))
        if runtime.hostStart?.locks != nil { emit(.contentFullscreen(false)) }
    }

    /// True from the Chromium Host's end with this tab's browser, or the one it was making
    /// (``hostEnded(_:)``), until the tab gets a browser again or closes: the tab shows the host's
    /// exit and has no browser, so what waited for it failed because the host ended.
    public var browserEndedWithHost: Bool { browserID == nil && !isClosed && state.processExit != nil }

    /// The page's process ended: the sad tab shows, now or when the tab is next shown, until the person
    /// reloads. False for a closed tab, which shows nothing.
    @discardableResult
    private func showProcessExit(_ exit: BrowserProcessExit) -> Bool {
        guard !isClosed else { return false }
        // A new renderer need not keep the old one's media emulation, so forget what the dead one was told:
        // whichever way the page comes back (Reload from the sad tab), the restarted
        // renderer's `.loadStart` sends the color scheme again rather than trusting a memo no live page heard.
        sentColorScheme = nil
        machine.apply(.processExited(exit))
        noteAudible()
        // The sad tab in this turn (a host's end cleared the page's context in it), not at the chrome's next render.
        crashPagePresenter?.showCrashPage(of: self)
        // After the sad tab, not before it: no first paint or load end is coming for the document that was
        // loading, so the page area stops standing in for it (`CEFTab+LoadingBackground`) -- but settling
        // repaints the base white, which would show for a frame in a dark theme before the sad tab.
        documentDidSettle()
        firstContentFrame.contentShown() // the sad tab is what a new tab shows
        findRequests.cancel()
        return true
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The renderer client ids of ``contentProcesses``; empty before the browser exists or
    /// without Chromium (`debug.webui`).
    public var rendererClientIDs: [Int32] {
        if case .chromiumRendererClients(let ids) = contentProcesses { ids } else { [] }
    }
    #endif
}

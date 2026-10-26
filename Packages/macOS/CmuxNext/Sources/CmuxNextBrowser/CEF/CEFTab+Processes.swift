public import CmuxNextWakeups
public import Foundation

extension CEFTab: BrowserProcessReporting {
    /// Renderer client ids hosting this tab's frames (main frame, out-of-process iframes; one per site).
    public var contentProcesses: BrowserContentProcesses {
        guard let browserID, let shim = runtime.shim else { return .none }
        var ids = [Int32](repeating: 0, count: 32)
        let count = ids.withUnsafeMutableBufferPointer { buffer in
            shim.rendererClientIDs(browserID, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return .none }
        return .chromiumRendererClients(Array(ids.prefix(Int(count))))
    }

    /// The pid of the renderer that hosts this tab's main frame (the fork's
    /// `cmux_cef_browser_renderer_pid`, p14-energy-124); same-site tabs can share it. Nil before the
    /// browser exists, while it has no renderer, on a fork without the call and in host mode
    /// (p14-energy-124a).
    public var rendererPID: pid_t? {
        guard let browserID, let shim = runtime.shim else { return nil }
        let pid = shim.rendererPID(browserID)
        return pid > 0 ? pid : nil
    }

    /// What this tab, as tab `id`, reports about its renderers (p14-energy-124): its main frame's renderer
    /// pid and the renderer client ids of all its frames. Two shim calls, no system call.
    public func renderers(tab id: String) -> ProcessUsage.TabRenderers {
        let clients: [Int32] = if case .chromiumRendererClients(let ids) = contentProcesses { ids } else { [] }
        return ProcessUsage.TabRenderers(tab: id, title: state.title ?? "", pid: rendererPID, rendererClients: clients)
    }

    /// Publishes this tab's ``renderers(tab:)`` as tab `id` into `directory` now, and again whenever they may
    /// change (``onRenderersMayChange``) while `isCurrent` says `id` still names this page: one tab per
    /// change, so the busy watchdog reads every tab's renderers off the main thread (p14-energy-124).
    public func publishRenderers(as id: String, into directory: TabRendererDirectory, while isCurrent: @escaping (CEFTab) -> Bool) {
        directory.update(renderers(tab: id))
        onRenderersMayChange = { [weak self] in
            guard let self, isCurrent(self) else { return }
            directory.update(self.renderers(tab: id))
        }
    }

    /// The renderer ended (crash, kill, out of memory, launch failure). The
    /// pane shows the sad tab; a hidden tab reloads when it is shown.
    func rendererTerminated(_ exit: BrowserProcessExit) {
        guard !isClosed else { return }
        // A new renderer need not keep the old one's media emulation, so forget
        // what the dead one was told: whichever way the page comes back (Reload
        // here, or a hidden tab reloading when shown), the restarted renderer's
        // `.loadStart` sends the color scheme again rather than trusting a memo
        // no live page ever heard.
        sentColorScheme = nil
        machine.apply(.processExited(exit))
        noteAudible()
        // After the sad tab, not before it: no first paint or load end is
        // coming for the document that was loading, so the page area stops
        // standing in for it (`CEFTab+LoadingBackground`) -- but settling
        // repaints the base white, and doing that before the view that reads
        // `state.processExit` is laid out shows a white page area for a frame
        // in a dark theme.
        documentDidSettle()
        firstContentFrame.contentShown() // the sad tab is what a new tab shows
        reloadWhenShown = host.visibleTab !== self
        findRequests.cancel()
        runtime.recordRendererExit(exit, tab: self)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The renderer client ids of ``contentProcesses``; empty before the browser exists or
    /// without Chromium (`debug.webui`).
    public var rendererClientIDs: [Int32] {
        if case .chromiumRendererClients(let ids) = contentProcesses { ids } else { [] }
    }
    #endif
}

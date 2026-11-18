public import Darwin

/// Ending a hung tab's renderer from the host (the agent-chat liveness watchdog, App Health's
/// `endRenderer`). Chromium offers the end only once its hang monitor fired (an input event went
/// unanswered), and a chat nobody touches never reports: a page stuck in a synchronous loop held
/// its renderer at 100% CPU and grew it past 14 GB, and closing the tab could not end it, because
/// the teardown runs on the main thread the loop holds (NIGHTLY 9d514c685e48, 2026-11-16).
extension CEFTab {
    /// The one renderer hosting this tab's frames (its `--renderer-client-id`); nil when the tab
    /// has none yet, or its frames span several renderers (an out-of-process iframe), so which one
    /// is the page's is not known.
    public var soleRendererClientID: Int32? {
        guard case .chromiumRendererClients(let ids) = contentProcesses, ids.count == 1 else { return nil }
        return ids.first
    }

    /// The process of ``soleRendererClientID``; nil when unknown or gone.
    public var soleRendererProcessID: Int32? {
        guard let client = soleRendererClientID else { return nil }
        return ChromiumHelperProcess.list().first { $0.kind == .renderer(clientID: client) }?.pid
    }

    /// Whether DevTools may hold the page on purpose: they are open (a breakpoint stops its main
    /// thread). A debugger on a process is the caller's check (`ProcessUsage.isTraced`).
    public var isBeingDebugged: Bool { devTools.isOpen }

    /// Ends the tab's renderer by force: Chromium's own answer when it reported the hang (its
    /// stored unresponsive callback), else SIGKILL to the one renderer process its frames live in.
    /// Chromium then reports the renderer gone to every tab in it (the crash path).
    ///
    /// - Returns: The pid ended (0 when Chromium's answer ended a process not mapped to a pid), or
    ///   nil when nothing was ended (no renderer, several, or the process already gone).
    public func endRenderer() -> Int32? {
        let pid = soleRendererProcessID
        if state.isUnresponsive, let browserID, runtime.shim?.unresponsiveReply(browserID, 1) == 1 {
            return pid ?? 0
        }
        // The renderer is the app's own child (ChromiumHelperProcess lists only those), mapped by
        // the client id its frames name; a hung main thread cannot take a gentler signal.
        guard let pid, pid > 0, kill(pid, SIGKILL) == 0 else { return nil }
        return pid
    }
}

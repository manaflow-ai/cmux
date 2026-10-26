#if DEBUG || CMUX_BENCH_HOOKS
extension CEFEngine {
    /// The Chromium browsers alive in this process now: each CEF tab's browser and each window Chromium is still
    /// creating, from the runtime's own routing tables. The oracle's `liveObjects.cefBrowsers` (p15-oracle-188), as
    /// a Chrome browser test reads its live hosts from their registry (`RenderProcessHost::AllHostsIterator`,
    /// content/public/browser/render_process_host.h), never from a counter kept for the test.
    public var liveBrowserCount: Int { CEFRuntime.shared.tabsByBrowser.count + CEFRuntime.shared.pendingWindows.count }
}
#endif

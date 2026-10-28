#if DEBUG || CMUX_BENCH_HOOKS
extension CEFEngine {
    /// The Chromium browsers alive in this process now, from the runtime's own routing tables: each CEF tab's browser
    /// and each browser Chromium created itself that still waits for a pane. The oracle's `liveObjects.cefBrowsers`,
    /// as a Chrome browser test reads its live hosts from their registry
    /// (`RenderProcessHost::AllHostsIterator`, content/public/browser/render_process_host.h), never from a counter
    /// kept for the test. A popup that is never adopted stays in the count, which is the leak I18 catches.
    public var liveBrowserCount: Int {
        let runtime = CEFRuntime.shared
        return Self.liveBrowsers(registered: Set(runtime.tabsByBrowser.keys), ledger: runtime.orphans.ledger,
                                 unplaced: Set(runtime.orphans.unplaced.keys))
    }

    /// Registered browsers plus the waiting ones (in the adoption ledger or unplaced) that are neither registered nor
    /// closed; a window Chromium is still creating is no browser yet.
    nonisolated static func liveBrowsers(registered: Set<Int32>, ledger: CEFAdoptionLedger, unplaced: Set<Int32>) -> Int {
        let waiting = unplaced.union(ledger.waiting.map(\.browser)).subtracting(registered)
        return registered.count + waiting.lazy.filter { !ledger.isClosed($0) }.count
    }
}
#endif

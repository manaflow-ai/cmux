import CmuxNextCompat
import Foundation

/// A Chromium tab's page states (task p01-process-093 of plans/cmux-next/chrome-parity/p01-process.md):
/// what the fork reported for each history entry, kept so the tab's saved history
/// (`frontend-browser-history-v1`) has each entry's page state, and the entries a restored tab
/// restores with theirs. Chrome keeps the same per entry for session restore
/// (`SerializedNavigationEntry::encoded_page_state`, components/sessions/core/serialized_navigation_entry.h).
nonisolated struct CEFTabPageStates: Equatable, Sendable {
    /// Bytes one entry's page state may take, as the Chromium Host bounds each push
    /// (`kMaxPageStateBytes`, ChromiumHost/src/host_page_state.h): a larger one is kept as none.
    static let maxStateBytes = 60 * 1024

    /// Feature `chromiumPageStateRestore` (``CEFRuntimeSource/keepsPageStates``): the tab watches
    /// and restores page states. Off, it does neither.
    var keeps = false
    /// Entries to restore with their page states once the browser exists, preferred over the
    /// navigation state (`cmux_shim_tab_restore_entries`).
    var pendingEntries: BrowserSavedSession?
    /// Each entry's last page state with the URL it showed then, by the fork's entry index.
    private(set) var byEntry: [Int: BrowserEntryPageState] = [:]
    /// The browser's entries at the last read: what a restart of the Chromium Host restores
    /// (``CEFTab/keepPageStatesForNextHost()``), since the host's list goes with it.
    private(set) var list: BrowserNavigationList?
    /// Entries the fork reported that the tab has not read yet.
    var reported: Set<Int32> = []

    /// A new browser: nothing reported or kept yet.
    mutating func reset() {
        byEntry = [:]
        list = nil
        reported = []
    }

    /// Keeps `state` for entry `index` showing `url`; none (nil `state` or `url`, or a state past
    /// ``maxStateBytes``) forgets it.
    /// - Returns: True when what is kept changed.
    mutating func set(_ state: String?, index: Int, url: URL?) -> Bool {
        let bounded = state.flatMap { $0.utf8.count <= Self.maxStateBytes ? $0 : nil }
        let kept = bounded.flatMap { state in url.map { BrowserEntryPageState(url: $0, state: state) } }
        guard byEntry[index] != kept else { return false }
        byEntry[index] = kept
        return true
    }

    /// The browser's entries as read with the reports.
    mutating func listed(_ entries: BrowserNavigationList?) {
        list = entries
    }

    /// Restored `entries` are the new browser's entries, in order, with their page states.
    mutating func seed(_ session: BrowserSavedSession) {
        for (index, entry) in session.entries.enumerated() {
            _ = set(entry.pageState, index: index, url: entry.url)
        }
        list = BrowserNavigationList(entries: session.entries.map(\.navigationEntry), current: session.current)
    }

    /// The kept entries with their page states, for a new browser of the same tab; nil when an entry
    /// has no URL, none has a page state, or one came from a form post (`formPost`), which a restore
    /// never sends again (BR-R1).
    func session(formPost: (URL) -> Bool) -> BrowserSavedSession? {
        guard let list, list.entries.indices.contains(list.current) else { return nil }
        var entries: [BrowserSavedEntry] = []
        for (index, entry) in list.entries.enumerated() {
            guard let url = entry.url, !formPost(url) else { return nil }
            let state = byEntry[index].flatMap { $0.url == url ? $0.state : nil }
            entries.append(BrowserSavedEntry(url: url, title: entry.title, pageState: state))
        }
        guard entries.contains(where: { $0.pageState != nil }) else { return nil }
        return BrowserSavedSession(entries: entries, current: list.current)
    }
}

extension CEFTab {
    /// The history a new browser starts with: entries with page states when the fork restores them,
    /// else the navigation state, else nothing (the URL loads). The watch comes first: the restore's
    /// commit is its first report. A refused entries restore falls back to the navigation state, then
    /// the URL, as an engine without the call does (``BrowserEngine``'s `restoreEntries`).
    func restoreHistory(browser: Int32) {
        watchPageStates(browser)
        if let entries = pageStates.pendingEntries {
            pageStates.pendingEntries = nil
            let fallback = pendingRestore
            pendingRestore = nil
            guard runtime.forkAPIVersion >= CEFShimPageStateOps.forkAPI else {
                return restoreFallback(fallback, browser: browser, trace: "restore-entries unsupported")
            }
            let sent = runtime.sendAsync { $0.pageStates.restoreEntries(browser, entries.entries, Int32(clamping: entries.current)) }
            // In process the fork's code comes now; in host mode in the host's REPLY.
            runtime.whenSettled(sent, label: "restore entries") { [weak self] answer in
                self?.entriesRestored(answer, entries, browser: browser, fallback: fallback)
            }
        } else if let state = pendingRestore {
            pendingRestore = nil
            restoreNavigation(state, browser: browser)
        }
    }

    /// The fork's answer to an entries restore: 1 restored, so the entries' states are the tab's; a
    /// refusal (0 unknown browser, -1 committed entries, -2 navigation not dropped, -3 bad entries)
    /// or an op no host got falls back. A passed deadline does not: the host may still restore.
    private func entriesRestored(_ answer: Result<Int32, CEFHostReplyError>, _ entries: BrowserSavedSession,
                                 browser: Int32, fallback: String?) {
        guard !isClosed, browserID == browser else { return }
        switch answer {
        case .success(1):
            host.lifecycleTrace.record(id, "restore-entries ok")
            pageStates.seed(entries)
        case .success(let code):
            restoreFallback(fallback, browser: browser, trace: "restore-entries failed(\(code))")
        case .failure(.unsent):
            restoreFallback(fallback, browser: browser, trace: "restore-entries unsent")
        case .failure(let error):
            host.lifecycleTrace.record(id, "restore-entries \(String(describing: error))")
        }
    }

    private func restoreFallback(_ state: String?, browser: Int32, trace: String) {
        host.lifecycleTrace.record(id, trace)
        if let state { return restoreNavigation(state, browser: browser) }
        if let url = pendingURL { runtime.shim?.loadURL(browser, url.absoluteString) }
    }

    private func restoreNavigation(_ state: String, browser: Int32) {
        // 1 = restored; fork API 10 reports why not (-1 committed entries,
        // -2 navigation not dropped, -3 state does not decode).
        let code = runtime.shim?.tabRestoreNavigation(browser, state) ?? 0
        host.lifecycleTrace.record(id, "restore-navigation \(code == 1 ? "ok" : "failed(\(code))")")
        if code != 1, let url = pendingURL { runtime.shim?.loadURL(browser, url.absoluteString) }
    }

    /// The Chromium Host ended with this tab's browser (``hostEnded(_:)``): its entries and their page
    /// states, kept here, are what its browser on the next host restores, as Chrome restores a crashed
    /// tab's `SerializedNavigationEntry`s with their `encoded_page_state`.
    func keepPageStatesForNextHost() {
        let formPosts = restored.formPostURLs
        guard pageStates.keeps, pageStates.pendingEntries == nil, !restored.showsFormSubmission,
              let session = pageStates.session(formPost: { formPosts.contains($0) }) else { return }
        pageStates.pendingEntries = session
    }

    /// The page goes to `url` before its browser exists: kept entries restore only for their own
    /// current address (the restored page's first load, a Reload after a host restart), not for a
    /// load elsewhere.
    func pendingLoad(_ url: URL) {
        guard let entries = pageStates.pendingEntries else { return }
        if !entries.entries.indices.contains(entries.current) || entries.entries[entries.current].url.absoluteString != url.absoluteString {
            pageStates.pendingEntries = nil
        }
    }

    /// Whether this tab restores `entries` with their page states: the feature is on, the fork has
    /// the calls, and an entry has one.
    func restoresPageStates(_ entries: BrowserSavedSession) -> Bool {
        pageStates.keeps && runtime.forkAPIVersion >= CEFShimPageStateOps.forkAPI && entries.entries.contains { $0.pageState != nil }
    }

    /// A tab Chromium opened from `opener` keeps page states as its opener does; it was attached
    /// before it knew, so its watch starts now.
    func inheritPageStates(from opener: CEFTab?) {
        pageStates.keeps = opener?.pageStates.keeps ?? false
        if let browserID { watchPageStates(browserID) }
    }

    /// The fork reported entry `index`: it is read on a later run-loop turn, once for every report
    /// of that turn, never inside the fork's call.
    func pageStateReported(index: Int32) {
        guard !isClosed, index >= 0 else { return }
        let first = pageStates.reported.isEmpty
        pageStates.reported.insert(index)
        if first { MainRunLoopBlock.perform { [weak self] in self?.readReportedPageStates() } }
    }

    /// The page states the fork reported for its own list's entries (`CEFRestoredSessionHost`).
    func nativePageStates() -> [Int: BrowserEntryPageState] {
        pageStates.byEntry
    }

    private func watchPageStates(_ browser: Int32) {
        pageStates.reset()
        guard pageStates.keeps, let shim = runtime.shim, runtime.forkAPIVersion >= CEFShimPageStateOps.forkAPI,
              let context = runtime.callbackToken?.context else { return }
        _ = unsafe shim.pageStates.watch(browser, CEFPageStateCallbacks.watch, context)
    }

    /// Reads each reported entry once and keeps what changed (the turn after the reports).
    func readReportedPageStates() {
        let indices = pageStates.reported
        pageStates.reported = []
        guard let browserID, let shim = runtime.shim, !isClosed else { return }
        let list = nativeNavigationList()
        pageStates.listed(list)
        let entries = list?.entries ?? []
        var changed = false
        for index in indices.sorted() {
            let entry = Int(index)
            let url = entries.indices.contains(entry) ? entries[entry].url : nil
            changed = pageStates.set(shim.pageStates.entryPageState(browserID, index), index: entry, url: url) || changed
        }
        if changed { pageStateRevision &+= 1 }
    }
}

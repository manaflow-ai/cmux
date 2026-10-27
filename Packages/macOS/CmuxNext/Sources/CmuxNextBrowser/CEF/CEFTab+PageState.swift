import CmuxNextCompat
import Foundation

/// A Chromium tab's page states (task p01-process-093 of plans/cmux-next/chrome-parity/p01-process.md):
/// what the fork reported for each history entry, kept so the tab's saved history
/// (`frontend-browser-history-v1`) has each entry's page state, and the entries a restored tab
/// restores with theirs. Chrome keeps the same per entry for session restore
/// (`SerializedNavigationEntry::encoded_page_state`, components/sessions/core/serialized_navigation_entry.h).
nonisolated struct CEFTabPageStates: Equatable, Sendable {
    /// Feature `chromiumPageStateRestore` (``CEFRuntimeSource/keepsPageStates``): the tab watches
    /// and restores page states. Off, it does neither.
    var keeps = false
    /// Entries to restore with their page states once the browser exists, preferred over the
    /// navigation state (`cmux_shim_tab_restore_entries`).
    var pendingEntries: BrowserSavedSession?
    /// Each entry's last page state with the URL it showed then, by the fork's entry index.
    private(set) var byEntry: [Int: BrowserEntryPageState] = [:]
    /// Entries the fork reported that the tab has not read yet.
    var reported: Set<Int32> = []

    /// A new browser: nothing reported or kept yet.
    mutating func reset() {
        byEntry = [:]
        reported = []
    }

    /// Keeps `state` for entry `index` showing `url`; none (nil `state` or `url`) forgets it.
    /// - Returns: True when what is kept changed.
    mutating func set(_ state: String?, index: Int, url: URL?) -> Bool {
        let kept = state.flatMap { state in url.map { BrowserEntryPageState(url: $0, state: state) } }
        guard byEntry[index] != kept else { return false }
        byEntry[index] = kept
        return true
    }

    /// Restored `entries` are the new browser's entries, in order, with their page states.
    mutating func seed(_ entries: [BrowserSavedEntry]) {
        for (index, entry) in entries.enumerated() {
            _ = set(entry.pageState, index: index, url: entry.url)
        }
    }
}

extension CEFTab {
    /// The history a new browser starts with: entries with page states when the fork restores them,
    /// else the navigation state, else nothing (the URL loads). The watch comes first: the restore's
    /// commit is its first report.
    func restoreHistory(browser: Int32) {
        watchPageStates(browser)
        if let entries = pageStates.pendingEntries {
            pageStates.pendingEntries = nil
            pendingRestore = nil
            let code = runtime.shim?.pageStates.restoreEntries(browser, entries.entries, Int32(clamping: entries.current)) ?? 0
            host.lifecycleTrace.record(id, "restore-entries \(code == 1 ? "ok" : "failed(\(code))")")
            if code == 1 {
                pageStates.seed(entries.entries)
            } else if let url = pendingURL {
                runtime.shim?.loadURL(browser, url.absoluteString)
            }
        } else if let state = pendingRestore {
            pendingRestore = nil
            // 1 = restored; fork API 10 reports why not (-1 committed entries,
            // -2 navigation not dropped, -3 state does not decode).
            let code = runtime.shim?.tabRestoreNavigation(browser, state) ?? 0
            host.lifecycleTrace.record(id, "restore-navigation \(code == 1 ? "ok" : "failed(\(code))")")
            if code != 1, let url = pendingURL { runtime.shim?.loadURL(browser, url.absoluteString) }
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
        let entries = nativeNavigationList()?.entries ?? []
        var changed = false
        for index in indices.sorted() {
            let entry = Int(index)
            let url = entries.indices.contains(entry) ? entries[entry].url : nil
            changed = pageStates.set(shim.pageStates.entryPageState(browserID, index), index: entry, url: url) || changed
        }
        if changed { pageStateRevision &+= 1 }
    }
}

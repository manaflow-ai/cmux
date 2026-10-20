import CmuxNextBrowserHistory
import CmuxNextDaemon
import Foundation

/// A closing browser tab's record and history (cx-d0d.73): the daemon copies
/// both into Reopen Closed at the close and then deletes them, so the page's
/// newest ones (a navigation still in the write-back delay, the scroll
/// position) are saved first, and `untrack` would drop a pending write. The
/// two must agree: a reopened tab restores the history only at the record's page.
extension BrowserTabService {
    /// How long a close waits for its pages' history: the scroll
    /// measurement's budget and one daemon write. The tabs are already
    /// hidden, so Cmd-W does not wait on it.
    static let closeFlushBudget: Duration = .milliseconds(700)

    /// ``flushHistory(_:within:)`` for the pages of `surfaces` on `machine`.
    func flushHistory(machine: String, surfaces: [SurfaceID]) async {
        let closing = Set(surfaces)
        let keys = Set(writers.keys).union(historyWriters.keys).filter { key in
            guard let tab = tabModel(key), closing.contains(tab.surface) else { return false }
            return daemonForTab(tab).machineID == machine
        }
        await flushHistory(keys, within: Self.closeFlushBudget)
    }

    /// Saves the records and history of `keys` now, scroll included,
    /// waiting at most `limit`.
    func flushHistory(_ keys: Set<String>, within limit: Duration) async {
        let records = keys.compactMap { writers[$0] }, histories = keys.compactMap { historyWriters[$0] }
        guard !records.isEmpty || !histories.isEmpty else { return }
        _ = await BrowserHistoryWriter.within(limit, sleep: sleep) {
            for record in records { await record.flushNow() }
            // Each page is asked for its scroll position at once, not in turn.
            // task-owner: every flush is awaited here, or finishes unawaited after the budget.
            let flushes = histories.map { writer in Task { await writer.flushNow() } }
            for flush in flushes { await flush.value }
            return true
        }
    }
}

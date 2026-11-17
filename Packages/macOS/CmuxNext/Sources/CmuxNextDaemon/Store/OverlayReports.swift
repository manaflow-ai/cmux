import Foundation

/// What the store tells the app when an apply ends: each created tab (`DaemonStore.onTabCreated`, `onPageTabCreated`
/// for a page tab), then each settled intent (`DaemonStore.onIntentSettled`).
///
/// The store applies the daemon's events with its pending intents lifted (`DaemonStore.withOverlayLifted`). During
/// the apply the records are the daemon's: a tab that a pending close hides is in them again. The report of a created
/// tab ran inside the apply, and the app maps a pane's strip in that report (it moves the selection from the stand-in
/// to the daemon's tab): the pane showed the closed tab again for one frame. Decision of 2026-11-16: that frame is a
/// fault. So the store keeps each report for the end of the apply, in the same turn: the pending intents are back on
/// the records, and the store has published the lists that changed.
@MainActor
enum OverlayReports {
    /// Sends the reports of the apply that ended. It takes both queues first: a report can start an apply of its own,
    /// and that apply then sends only its own reports.
    static func send(from store: DaemonStore) {
        let created = store.intentLog.takeCreatedToReport()
        let settled = store.intentSettlements
        store.intentSettlements.removeAll()
        // The created tabs first: the app moves a stand-in's state to its tab before it hears that the creation settled.
        for report in created {
            if report.page { store.onPageTabCreated?(report.id, report.tab) } else { store.onTabCreated?(report.id, report.tab) }
        }
        for (transaction, settlement) in settled { store.onIntentSettled?(transaction, settlement) }
    }
}

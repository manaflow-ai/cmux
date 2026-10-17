import CmuxBrowser
import Foundation

/// Reopen Closed Tab brings back a Chromium tab's back/forward history, as
/// Chrome's Cmd-Shift-T does and cmux Next's `ClosedBrowserHistories` does.
///
/// The closed-item record (`ClosedPanelHistoryEntry`) keeps the session
/// snapshot, which holds a WebKit page's history (`interactionState`) but
/// not Chromium's. Each closing Chromium page's navigation state is kept
/// here in memory, by the closed panel's id, for as many closes as the
/// closed-item history keeps; the reopen hands it to the new page in place
/// of its first load. After a relaunch the tab reopens at its address, as
/// before.
@MainActor
final class ClosedBrowserNavigationStates {
    static let shared = ClosedBrowserNavigationStates()

    /// The closed-item history keeps at most this many records.
    static let limit = 50
    /// Saved states, oldest first.
    private var saved: [(panelID: UUID, state: BrowserPageRestoreState)] = []

    /// Keeps a closing panel's history.
    func save(_ state: BrowserPageRestoreState, for panelID: UUID) {
        saved.removeAll { $0.panelID == panelID }
        saved.append((panelID, state))
        if saved.count > Self.limit { saved.removeFirst(saved.count - Self.limit) }
    }

    /// The history a closed panel left, if any.
    func state(for panelID: UUID) -> BrowserPageRestoreState? {
        saved.last { $0.panelID == panelID }?.state
    }

    /// Forgets a closed panel's history once its reopen used it.
    func remove(_ panelID: UUID) {
        saved.removeAll { $0.panelID == panelID }
    }

    /// Forgets every saved history (Clear Recently Closed).
    func removeAll() {
        saved.removeAll()
    }
}

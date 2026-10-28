public import CmuxNextDaemon

extension DaemonService {
    /// Cancels the creation that shows provisional tab `id` (``CancelledCreationClose``); false for any other tab.
    public func cancelCreation(tab id: String) -> Bool { CancelledCreationClose(daemon: self).cancel { $0.cancel(tab: id) } }

    /// Cancels the pending split whose provisional pane shows tab `id` (Close Pane while its focus is on its way).
    public func cancelSplit(showing id: String) -> Bool { CancelledCreationClose(daemon: self).cancel { $0.cancel(splitShowing: id) } }

    /// Cancels the split that shows provisional pane `handle`; false for any other pane.
    public func cancelCreation(pane handle: PaneID) -> Bool { CancelledCreationClose(daemon: self).cancel { $0.cancel(pane: handle) } }
}

/// A person's close of a tab or pane this client is still creating ("Close before create",
/// .cmux-scratch/motion-redesign/DESIGN.md 2026-10-18). The store takes it out of the visible
/// state at once and hides the daemon's object when it comes (``DaemonCreations``); this closes
/// that object as soon as its surface is known, in one `close-tabs` commit that ends its terminal
/// and stays out of the closed history (`session_end`): the tab never existed for the person, so
/// Reopen Closed Tab never offers it.
@MainActor struct CancelledCreationClose {
    let daemon: DaemonService

    func cancel(_ body: (DaemonCreations) -> Bool) -> Bool {
        let creations = daemon.store.creations
        if !creations.closes {
            creations.onClose { [weak daemon] transaction, surface in
                if let daemon { CancelledCreationClose(daemon: daemon).close(transaction, surface) }
            }
        }
        return body(creations)
    }

    private func close(_ transaction: ClientTransactionID, _ surface: SurfaceID) {
        let batch = daemon.supports(DaemonCapability.batchClose.rawValue)
        let reason: CloseReason? = daemon.supports(DaemonCapability.closeReason.rawValue) ? .sessionEnd : nil
        let daemon = daemon
        let run: DaemonCommandBody = { connection in
            if batch { _ = try await connection.closeTabs([surface], endTerminals: true, reason: reason) } else { try await connection.closeTab(surface) }
        }
        // task-owner: one close of a cancelled creation's daemon tab; its failure shows what the daemon kept
        Task {
            switch await daemon.runReportingTimeout("close-tabs (cancelled creation)", run) {
            case .succeeded:
                break // the intent leaves once the records drop the tab
            case .failed:
                // The daemon kept it (or the link dropped): the records show what it has.
                daemon.store.rejectIntent(transaction)
            case .unknown:
                // Under load the close usually still commits: never show the tab for a lost
                // reply (tab-spam-race). A snapshot ordered after the close says; a tab still
                // there gets its close again.
                await daemon.store.refresh()
                daemon.store.creations.closeTimedOut(transaction)
            }
        }
    }
}

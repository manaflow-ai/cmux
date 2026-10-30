import AppKit
import CmuxNextBridge
import CmuxNextDaemonService

extension PaneController {
    /// One close gesture over tabs of several panes of one daemon (Close
    /// Other Panes): each pane runs its local half (`prepareClose`), then
    /// every tab goes in ONE daemon close (`close-tabs`, `batch-close-v1`), so
    /// the daemon stores one closed group and one Reopen Closed (Cmd-Shift-T)
    /// brings every pane back with its tabs. Parts on other daemons, or one
    /// part alone, close as a pane's own close does.
    static func close(_ parts: [(pane: PaneController, ids: [StripTabID])]) {
        guard let first = parts.first?.pane else { return }
        let daemon = first.daemon
        guard parts.count > 1, parts.allSatisfy({ $0.pane.daemon === daemon }) else {
            for part in parts { part.pane.close(part.ids) }
            return
        }
        send(parts.compactMap { $0.pane.prepareClose($0.ids) }, from: first, userClose: CloseUndoToasts.isUserClose)
    }

    /// Sends the daemon halves of closes whose local halves already ran
    /// (`prepareClose`), every pane on `first`'s daemon, in ONE daemon close:
    /// one closed group, one Reopen Closed step. A close that waited for its
    /// pages (`PageDecidedCloses`) prepares its tabs at two moments and
    /// sends them here together. `userClose`: a refused close shows
    /// `RefusedCloseNotice`.
    static func send(_ prepared: [PreparedTabClose], from first: PaneController, userClose: Bool) {
        guard !prepared.isEmpty else { return }
        let daemon = first.daemon
        let runs = daemon.closeRuns(surfaces: prepared.flatMap(\.surfaces), commands: prepared.flatMap(\.commands))
        let services = first.services, window = first.view.window
        services.registry.track(Task { [services, weak window] in
            let outcome = await daemon.runReportingOutcomes(runs)
            if outcome.failed, userClose { RefusedCloseNotice(services: services).show(codes: outcome.codes, in: window) }
            for part in prepared { await part.finish(outcome.failed, outcome.unknown) }
            return outcome.failed ? "close failed (see the app log)" : nil
        })
    }
}

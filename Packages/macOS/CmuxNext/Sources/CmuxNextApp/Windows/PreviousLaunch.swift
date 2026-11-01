import CmuxNextDaemon
import CmuxNextLayout
import Foundation

/// What the previous app launch left open, as this launch restored it: the windows its saved
/// records had open (front first) and when this launch restored them. Restore Previous App
/// Launch (`reopenPreviousSession`) reopens what of it was closed since (``plan(closed:registry:install:)``).
/// Captured once by `WindowManager.restore`; nil before that and when nothing was saved.
struct PreviousLaunch: Equatable, Sendable {
    /// Window ids open at the end of the previous launch, front first.
    var windowIDs: [String]
    /// This launch's restore time (ms since 1970): a close at or after it happened in this launch.
    var restoredAtMs: UInt64

    /// What Restore Previous App Launch reopens.
    struct Plan: Equatable, Sendable {
        /// Closed-history items (`closed_…`) to reopen, windows first, then workspaces, oldest close first.
        var closedIDs: [String] = []
        /// Closed windows with no closed-history item (a daemon without window records) to reopen directly.
        var windowIDs: [String] = []

        var isEmpty: Bool { closedIDs.isEmpty && windowIDs.isEmpty }
    }

    /// The reopen plan against `closed` (one daemon's closed history, any order) and this
    /// launch's `registry`. A window of the previous launch that is closed now comes back by its
    /// `window` item (closed in this launch), else directly. A workspace closed in this launch
    /// from one of those windows (its item names that window's record `install/window`) comes back
    /// too; a deleted workspace group, a tab or a screen does not. `install` is this install's id
    /// (nil: window records are not kept, so only direct window reopens apply).
    func plan(closed: [ClosedItem], registry: WindowRegistry, install: String?) -> Plan {
        let records = Dictionary(uniqueKeysWithValues: windowIDs.compactMap { id in install.map { ($0 + "/" + id, id) } })
        let recent = closed.filter { $0.closedAtMs >= restoredAtMs }.sorted { $0.closedAtMs < $1.closedAtMs }
        var plan = Plan()
        for id in windowIDs where registry.window(id)?.isOpen == false {
            let record = install.map { $0 + "/" + id }
            if let item = recent.last(where: { $0.kind == .window && $0.window != nil && $0.window == record }) {
                plan.closedIDs.append(item.id)
            } else {
                plan.windowIDs.append(id)
            }
        }
        for item in recent where item.kind == .workspace && item.group == nil {
            guard let window = item.window, records[window] != nil else { continue }
            plan.closedIDs.append(item.id)
        }
        return plan
    }
}

public import CmuxNextDaemon
import Foundation

/// The local session owner restoring while the app waits for it (Leo, 2026-11-08: a 30-minute restore
/// read only "cmux's background service isn't connected", and a click on a chat did nothing). The
/// launch window, the sidebar and the agent chat page show it from here.
extension DaemonService {
    /// The owner's restore while this daemon is not connected (``DaemonRecovery/restoring``); nil once
    /// it is, and while no `server ensure` reports a restore.
    public var restoring: RestoreProgressReport? {
        isLive ? nil : recovery.restoring
    }
}

nonisolated extension RefusalStrings {
    /// "Restoring sessions… 4m 12s": the owner's restore and how long the app has waited for it.
    public static func restoringSessions(waitedMs: UInt64) -> String {
        let waited = Duration.milliseconds(Int64(clamping: waitedMs / 1000 * 1000))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
        return String(format: text("refusal.daemon.restoringSessions", "Restoring sessions… %@"), waited)
    }
}

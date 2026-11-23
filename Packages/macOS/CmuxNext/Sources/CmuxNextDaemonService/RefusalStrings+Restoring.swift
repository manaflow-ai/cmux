import Foundation

/// The local session owner restoring while the app waits for it (Leo, 2026-11-08: a 30-minute restore read only
/// "cmux's background service isn't connected", and a click on a chat did nothing): the launch window and the
/// sidebar say so from ``DaemonRecovery/restoringText``, in these words, once the restore has lasted the shared
/// connection quiet time (Leo, 2026-11-22: "entire classes of bullshit fucking error/status bullshit. fuck em.
/// remove them all"). One calm line: no running clock.
nonisolated extension RefusalStrings {
    /// "Restoring your sessions…": the owner's restore, with no timer.
    public static var restoringSessions: String { text("refusal.daemon.restoringSessionsQuiet", "Restoring your sessions…") }
}

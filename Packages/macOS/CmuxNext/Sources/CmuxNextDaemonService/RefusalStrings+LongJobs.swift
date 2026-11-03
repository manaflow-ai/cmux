public import CmuxNextWakeups
import Foundation

/// Why an action waits while the local owner restores (plans/cmux-next/long-jobs-DESIGN.md): the
/// refusal names the job and how far it is, and says to wait. On 2026-11-02 a 303 s output cleanup
/// read "could not start ... Quit and reopen cmux", and quitting restarted the cleanup.
nonisolated extension RefusalStrings {
    /// The refusal while the owner restores with `jobs` (the first one that blocks startup, else the
    /// first one); with no job named, that terminals are still restoring.
    public static func restoring(_ jobs: [LongJob]) -> String {
        guard let job = jobs.first(where: { $0.holds(.startup) }) ?? jobs.first else {
            return text("handlers.refusal.restoringTerminals", "cmux is still restoring your terminals. Wait for it to finish.")
        }
        if job.kind == LongJob.outputCleanupKind, let percent = job.percentText {
            return format("handlers.refusal.restoringOutputCleanup",
                          "cmux is cleaning up stored terminal output (%@). Wait for it to finish; quitting now restarts it.", percent)
        }
        if let percent = job.percentText {
            return format("handlers.refusal.restoringJobProgress",
                          "cmux is busy: %1$@ (%2$@). Wait for it to finish; quitting now restarts it.", job.displayTitle, percent)
        }
        return format("handlers.refusal.restoringJob", "cmux is busy: %@. Wait for it to finish; quitting now restarts it.",
                      job.displayTitle)
    }
}

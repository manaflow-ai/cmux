import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// The expiry of a chat upload stager's stages and batches (the app's local and peer ``AgentPaneUploadStager``s):
/// one ``MainDeadline`` at the earliest expiry date, re-armed after each purge, instead of a sleeping task per chunk.
/// An expired stage's files are removed on the files lane, never on the main thread. The composition root owns one
/// per stager.
@MainActor
public final class AgentPaneUploadStageExpiry {
    /// What a purge took out: the files to remove and the next expiry date left, nil when none is left.
    public struct Purge: Sendable {
        public var files: [URL]
        public var next: Date?

        public init(files: [URL], next: Date?) {
            self.files = files
            self.next = next
        }
    }

    private let deadline: MainDeadline
    private let work: BackgroundWork

    public init(owner: String, deadlines: MainDeadlineScheduler, work: BackgroundWork) {
        self.work = work
        deadline = MainDeadline(owner: owner, workClass: .background, scheduler: deadlines)
    }

    /// True while an expiry is pending.
    public var isArmed: Bool { deadline.isScheduled }

    /// Points the deadline at `next` (at least 1 s from now), or drops it when `next` is nil. At the deadline
    /// `purge` takes out what expired by the date it gets; its files go off the main thread and the deadline
    /// moves to its next date. A chunk or a batch request that moves a date later re-arms, so the deadline only
    /// fires for stages that truly expired.
    public func arm(next: Date?, purge: @escaping @MainActor (_ now: Date) -> Purge) {
        guard let next else { deadline.cancel(); return }
        deadline.schedule(after: .seconds(max(1, next.timeIntervalSinceNow))) { [weak self] in
            guard let self else { return }
            let purged = purge(Date())
            remove(purged.files)
            arm(next: purged.next, purge: purge)
        }
    }

    private func remove(_ files: [URL]) {
        guard !files.isEmpty else { return }
        work.post(.bestEffort, mayBlock: .files) {
            for file in files { try? FileManager.checked.removeItem(at: file) }
        }
    }
}

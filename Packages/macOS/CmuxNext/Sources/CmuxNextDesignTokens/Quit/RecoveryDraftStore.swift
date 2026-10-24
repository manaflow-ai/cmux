package import CmuxNextWakeups
public import Foundation
package import os

/// The recovery-draft backstop (R96 quit hook). Participants call `update`
/// on every edit; after a short debounce on the injected clock the draft is
/// written crash-safe (temp file, fsync, rename) off the main actor, in a
/// 0700 directory as a 0600 file. `remove` (a normal save, a quit save, or
/// Don't Save) cancels a pending update first, so a stale draft never comes
/// back. The next launch reads `drafts()` and shows the restore notice.
@MainActor
public final class RecoveryDraftStore {
    public static let defaultMaxDraftBytes = 8 * 1024 * 1024
    public static let defaultMaxTotalBytes = 100 * 1024 * 1024

    public let directory: URL
    /// Opens a recovered draft in its editor (set by the editor side at launch).
    public var restoreHandler: ((RecoveryDraft) -> Void)?
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private let maxDraftBytes: Int
    private let maxTotalBytes: Int
    private var timers: [String: DemandTimer] = [:]
    private var pending: [String: RecoveryDraft] = [:]

    public init(directory: URL, clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .seconds(1),
                maxDraftBytes: Int = RecoveryDraftStore.defaultMaxDraftBytes,
                maxTotalBytes: Int = RecoveryDraftStore.defaultMaxTotalBytes) {
        self.directory = directory
        self.clock = clock
        self.debounce = debounce
        self.maxDraftBytes = maxDraftBytes
        self.maxTotalBytes = maxTotalBytes
    }

    /// Records the current unsaved contents; written after the debounce.
    /// The checks are synchronous: `.tooLarge` and `.invalidID` mean no
    /// draft is kept for this update. `id` is the participant's id,
    /// `file:<host id>:<canonical path>`; `host` (nil: the id's host) and
    /// `filePath` must agree with it. `base` is the file state the edits are
    /// based on, taken by the participant when it read or last saved the
    /// file; the launch check compares the file with it. Without a base the
    /// draft records the file's date and size at the delayed write.
    @discardableResult
    public func update(id: String, title: String, contents: Data, host: String? = nil,
                       filePath: String? = nil, base: RecoveryDraftBase? = nil) -> RecoveryDraftAcceptance {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "recovery-drafts")
        guard let parts = QuitParticipantID.parse(id) else {
            logger.error("refused recovery draft id (\(QuitParticipantID.shape(id), privacy: .public))")
            return .invalidID
        }
        guard host.map({ $0 == parts.host }) ?? true, filePath.map({ $0 == parts.path }) ?? true else {
            logger.error("refused recovery draft: its host or file path disagrees with its id")
            return .invalidID
        }
        guard contents.count <= maxDraftBytes else { return .tooLarge }
        let base = base.flatMap { $0.isEmpty ? nil : $0 }
        pending[id] = RecoveryDraft(id: id, host: parts.host, title: title, savedAt: Date(), contents: contents, filePath: filePath,
                                    fileModified: base?.modified, fileSize: base?.size, base: base)
        let timer = timers[id] ?? DemandTimer(owner: "recovery-draft", clock: clock)
        timers[id] = timer
        timer.schedule(after: debounce) { @MainActor [weak self] in await self?.writeNow(id) }
        return .kept
    }

    /// Drops the draft of `id` and any update still waiting for its debounce.
    public func remove(id: String) async {
        timers.removeValue(forKey: id)?.cancel()
        pending[id] = nil
        await RecoveryDraftFiles.delete(id: id, in: directory)
    }

    /// Writes every pending update now (a quit that cannot wait).
    public func writePending() async {
        for id in Array(pending.keys) {
            timers.removeValue(forKey: id)?.cancel()
            await writeNow(id)
        }
    }

    /// Every draft on disk (read at launch).
    public func drafts() async -> [RecoveryDraft] {
        await RecoveryDraftFiles.readAll(in: directory)
    }

    /// Whether the document's file differs from the draft's base, or (with
    /// no base) changed after the draft was written. A draft of another host
    /// is never compared with a local file.
    public func fileChangedSince(_ draft: RecoveryDraft) async -> Bool {
        await RecoveryDraftFiles.changedSince(draft)
    }

    private func writeNow(_ id: String) async {
        guard let draft = pending.removeValue(forKey: id) else { return }
        timers[id] = nil
        await RecoveryDraftFiles.write(draft, in: directory, maxTotalBytes: maxTotalBytes)
    }
}

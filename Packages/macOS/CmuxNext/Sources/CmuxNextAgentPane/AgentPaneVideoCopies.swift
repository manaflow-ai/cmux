import CmuxNextWakeups
import Foundation

/// The private copies of attached videos (``AgentPaneVideoInfo/snapshot(_:in:into:matching:)``)
/// that a video's reads share: its poster (`video.info`), key frames and probes (`video.probes`),
/// picked frames (`video.frames`) and speech (`video.transcript`) read one copy of the file as it
/// is (``AgentPaneVideoInfo/FileIdentity``). A dropped file is cloned, or on a disk that cannot
/// clone it copied (up to ``AgentPaneVideoInfo/maximumCopyBytes``), once instead of once per read;
/// a file changed since gets a new copy. A copy no read holds is removed after ``idle``.
final class AgentPaneVideoCopies {
    /// How long a copy no read holds is kept for the next read of the same file.
    static let idle: Duration = .seconds(120)

    private struct Entry {
        /// Makes the copy once; every read of the file awaits the same.
        var copy: Task<URL?, Never>
        var readers = 0
        var lastUse = ContinuousClock.now
    }

    private var entries: [AgentPaneVideoInfo.FileIdentity: Entry] = [:]
    private let expiry = DemandTimer(owner: "agent-pane.video-copies")

    /// The copy of `file`, made by `make` (off the main actor) for the first read of it; nil when
    /// none could be made. Hand each copy taken back with ``release(_:)``.
    func take(_ file: AgentPaneVideoInfo.FileIdentity, make: @escaping @Sendable () async -> URL?) async -> URL? {
        // task-owner: the copy of one file, shared by its reads; the entry keeps it and `purge` removes it.
        var entry = entries[file] ?? Entry(copy: Task(priority: WorkPriority.userVisible.taskPriority) { await make() })
        entry.readers += 1
        entries[file] = entry
        guard let copy = await entry.copy.value else {
            // Nothing to share: the next read tries again.
            entries[file]?.readers -= 1
            if entries[file]?.readers == 0 { entries.removeValue(forKey: file) }
            return nil
        }
        return copy
    }

    /// One read of `file`'s copy is done.
    func release(_ file: AgentPaneVideoInfo.FileIdentity) {
        guard var entry = entries[file] else { return }
        entry.readers = max(0, entry.readers - 1)
        entry.lastUse = .now
        entries[file] = entry
        arm()
    }

    /// Removes the copies no read has held for ``idle``.
    private func purge() async {
        let idle = { (entry: Entry) in entry.readers == 0 && ContinuousClock.now - entry.lastUse >= Self.idle }
        for file in entries.filter({ idle($0.value) }).map(\.key) {
            // Checked again: a read may have taken it while an earlier copy was removed.
            guard let entry = entries[file], idle(entry) else { continue }
            entries.removeValue(forKey: file)
            if let copy = await entry.copy.value { await AgentPaneVideoInfo.discard(copy) }
        }
        arm()
    }

    /// Arms the one deadline while a copy waits unheld; none otherwise.
    private func arm() {
        guard entries.values.contains(where: { $0.readers == 0 }) else { expiry.cancel(); return }
        expiry.schedule(after: Self.idle) { @MainActor [weak self] in await self?.purge() }
    }
}

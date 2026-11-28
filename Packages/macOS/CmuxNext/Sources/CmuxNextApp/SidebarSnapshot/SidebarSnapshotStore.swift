import CmuxNextWakeups
import Foundation

/// Repository of the saved sidebars (`SidebarSnapshotDocument`) behind one
/// `SidebarSnapshotFile`. The document is read once, synchronously, when
/// the store is made (before the first window), and kept as
/// ``launchDocument`` for the windows a launch opens. Changes are written
/// 500 ms after the last one and at once by ``flush()`` (quit). Without a
/// file (tests, previews) it keeps the document in memory only.
actor SidebarSnapshotStore {
    /// What the last run saved, read before the first window.
    nonisolated let launchDocument: SidebarSnapshotDocument
    private(set) var document: SidebarSnapshotDocument
    /// Completed file writes (tests).
    private(set) var writeCount = 0
    private let file: SidebarSnapshotFile?
    private let debounce: Duration
    private let timer: DemandTimer
    private var dirty = false
    /// The newest sequence recorded per window: a late record never rolls
    /// a window back (records travel in separate tasks).
    private var sequences: [String: UInt64] = [:]

    init(file: SidebarSnapshotFile?, clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .milliseconds(500)) {
        let loaded = file?.read() ?? SidebarSnapshotDocument()
        launchDocument = loaded
        document = loaded
        self.file = file
        self.debounce = debounce
        timer = DemandTimer(owner: "SidebarSnapshotStore.write", clock: clock)
    }

    /// Saves window `windowID`'s sidebar. `sequence` orders the records of
    /// one window; an older one than the last is ignored.
    func record(_ snapshot: SidebarSnapshot, window windowID: String, sequence: UInt64) {
        if let last = sequences[windowID], last >= sequence { return }
        sequences[windowID] = sequence
        if document.record(snapshot, window: windowID) { scheduleWrite() }
    }

    /// The user used window `windowID`: it is the one a launch draws first.
    func touch(window windowID: String) {
        if document.touch(window: windowID) { scheduleWrite() }
    }

    /// The user closed window `windowID`.
    func forget(window windowID: String) {
        sequences[windowID] = nil
        if document.forget(window: windowID) { scheduleWrite() }
    }

    /// Writes pending changes now (quit).
    func flush() {
        timer.cancel()
        guard dirty else { return }
        dirty = false
        guard let file else { return }
        do {
            try file.write(document)
            writeCount += 1
        } catch {
            dirty = true
        }
    }

    private func scheduleWrite() {
        dirty = true
        timer.schedule(after: debounce) { [weak self] in await self?.flush() }
    }
}

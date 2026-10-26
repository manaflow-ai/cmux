import CmuxNextDesign
import CmuxNextWakeups
import Foundation

/// Repository of the saved sidebars (`SidebarSnapshotDocument`) behind one
/// `SidebarSnapshotFile`. The document is read once on the files lane from
/// `main` (``SidebarSnapshotFile/startLaunchRead(in:reader:)``), never on the
/// main thread, and kept as ``launchDocument`` for the windows a launch
/// opens. Changes are written 500 ms after the last one and at once by
/// ``flush()`` (quit); a change that comes before the read has ended waits
/// for it, so a write never drops the windows the last run saved. Without a
/// file (tests, previews) it keeps the document in memory only.
actor SidebarSnapshotStore {
    /// What the last run saved; nil while it is read (empty when nothing was saved).
    private nonisolated let saved: LaunchRead<SidebarSnapshotDocument>?
    /// The saved document with every change applied; the saved one is in it once ``isLoaded``.
    private(set) var document = SidebarSnapshotDocument()
    /// Completed file writes (tests).
    private(set) var writeCount = 0
    private let file: SidebarSnapshotFile?
    private let debounce: Duration
    private let timer: DemandTimer
    private var dirty = false
    /// ``document`` holds the saved document (or there is none to read).
    private var isLoaded: Bool
    /// Changes made before the saved document was read, in order.
    private var waiting: [(inout SidebarSnapshotDocument) -> Bool] = []
    /// The newest sequence recorded per window: a late record never rolls
    /// a window back (records travel in separate tasks).
    private var sequences: [String: UInt64] = [:]

    /// - Parameters:
    ///   - file: Where changes are written; nil keeps them in memory.
    ///   - saved: The file's launch read; nil with no file.
    ///   - clock: The write debounce's clock.
    ///   - debounce: How long after the last change the file is written.
    init(file: SidebarSnapshotFile?, saved: LaunchRead<SidebarSnapshotDocument>? = nil,
         clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .milliseconds(500)) {
        self.saved = saved
        isLoaded = saved == nil
        self.file = file
        self.debounce = debounce
        // timer-class-allow: off-main: the debounced file write runs on this actor; it never wakes the main thread
        timer = DemandTimer(owner: "SidebarSnapshotStore.write", clock: clock)
    }

    /// What the last run saved, for the windows a launch opens: empty while the read runs (`main` orders it before
    /// the settings read, so it has ended when the first window is built). Never waits.
    nonisolated var launchDocument: SidebarSnapshotDocument {
        saved?.value ?? SidebarSnapshotDocument()
    }

    /// Saves window `windowID`'s sidebar. `sequence` orders the records of
    /// one window; an older one than the last is ignored.
    func record(_ snapshot: SidebarSnapshot, window windowID: String, sequence: UInt64) {
        if let last = sequences[windowID], last >= sequence { return }
        sequences[windowID] = sequence
        apply { $0.record(snapshot, window: windowID) }
    }

    /// The user used window `windowID`: it is the one a launch draws first.
    func touch(window windowID: String) {
        apply { $0.touch(window: windowID) }
    }

    /// The user closed window `windowID`.
    func forget(window windowID: String) {
        sequences[windowID] = nil
        apply { $0.forget(window: windowID) }
    }

    /// Writes pending changes now (quit), after the saved document's read when it still runs.
    func flush() async {
        timer.cancel()
        if !isLoaded, let saved {
            let value = await saved.finished()
            if load(value) { dirty = true }
        }
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

    /// Applies `change` to the document, or keeps it until the saved document is read.
    private func apply(_ change: @escaping (inout SidebarSnapshotDocument) -> Bool) {
        if !isLoaded, let value = saved?.value, load(value) { scheduleWrite() }
        guard isLoaded else {
            waiting.append(change)
            // The debounced write's flush waits for the read, then applies the change on the saved document.
            scheduleWrite()
            return
        }
        if change(&document) { scheduleWrite() }
    }

    /// The saved document is read: it becomes the base, and the changes made while it was read apply on it in order.
    /// - Returns: Whether a waiting change changed it.
    private func load(_ value: SidebarSnapshotDocument) -> Bool {
        guard !isLoaded else { return false }
        isLoaded = true
        document = value
        let changes = waiting
        waiting = []
        var changed = false
        for change in changes {
            if change(&document) { changed = true }
        }
        return changed
    }

    private func scheduleWrite() {
        dirty = true
        timer.schedule(after: debounce) { [weak self] in await self?.flush() }
    }
}

import CmuxNextCompat
import CmuxNextWakeups
import Darwin
public import Foundation

/// Keep in Sync: watches the history database of every synced source and,
/// ``delay`` after its browser writes it, reads the pages again into that
/// source's saved batch (``ImportedDataStore/replaceHistory(_:with:)``) and
/// hands them to `deliver`, the profile's live history. Re-reading is
/// idempotent: pages merge by URL. Nothing polls: kqueue events on the
/// database, its `-wal` and its folder (each Chromium write makes and deletes
/// `History-journal`), then one coalesced read. ``reconcile()`` starts and
/// stops watches to match the store, with one catch-up read per new watch.
public actor ImportHistorySync {
    public typealias Deliver = @Sendable (_ profile: String, _ pages: [ImportedHistoryEntry]) async -> Void

    private let store: ImportedDataStore
    private let grants: BrowserFolderGrants?
    private let delay: Duration
    private let limit: Int
    private let deliver: Deliver
    private var watches: [String: HistoryFileWatch] = [:]
    private var timers: [String: DemandTimer] = [:]

    /// `grants`: the folder grants reads need (nil: folders are read directly).
    public init(store: ImportedDataStore, grants: BrowserFolderGrants?, delay: Duration = .seconds(20),
                limit: Int = ImportPlan.defaultHistoryLimit, deliver: @escaping Deliver) {
        self.store = store
        self.grants = grants
        self.delay = delay
        self.limit = limit
        self.deliver = deliver
    }

    /// The sources being watched now.
    public var watched: Set<String> { Set(watches.keys) }

    /// Watches every synced source of the store: new ones start (and read
    /// once), ones no longer synced stop.
    public func reconcile() async {
        let records = await store.syncedSources()
        let keys = Set(records.map(\.sourceKey))
        for key in watches.keys where !keys.contains(key) { end(key) }
        for record in records {
            guard let file = record.syncedHistoryFile, watches[record.sourceKey]?.file != file else { continue }
            end(record.sourceKey)
            let key = record.sourceKey
            watches[key] = HistoryFileWatch(file: file, scope: grants?.grantedFolder(record.browser)) { [weak self] in
                // task-owner: one hop from the kqueue handler into the actor; the timer coalesces
                Task { await self?.changed(key) }
            }
            changed(key)
        }
    }

    /// At launch: hands every profile's saved pages to `deliver` (the omnibar
    /// starts with the imported history), then starts the watches.
    public func start(profiles: [String]) async {
        for profile in profiles {
            let pages = await store.batches(profile: profile).flatMap(\.history)
            if !pages.isEmpty { await deliver(profile, pages) }
        }
        await reconcile()
    }

    /// Stops every watch (the app is quitting, or the store went away).
    public func stop() {
        for key in watches.keys { end(key) }
    }

    private func end(_ key: String) {
        watches.removeValue(forKey: key)?.cancel()
        timers.removeValue(forKey: key)?.cancel()
    }

    /// A write arrived: one read `delay` later, however many writes follow.
    private func changed(_ key: String) {
        guard watches[key] != nil else { return }
        let timer = timers[key] ?? DemandTimer(owner: "ImportHistorySync")
        timers[key] = timer
        timer.scheduleIfIdle(after: delay) { [weak self] in await self?.refresh(key) }
    }

    /// Reads the source's pages again and hands them on; a source that went
    /// away or no longer reads is left as it was.
    func refresh(_ key: String) async {
        guard let watch = watches[key], let record = await store.syncedSources().first(where: { $0.sourceKey == key }) else { return }
        let limit = limit
        guard let pages = try? BrowserImporter.readHistory(record.browser.family, file: watch.file, limit: limit),
              let saved = try? await store.replaceHistory(key, with: pages) else { return }
        await deliver(saved.targetProfileID, pages)
    }
}

/// kqueue sources on one history database, its `-wal` and its folder; any
/// event calls `onChange`. A file the browser replaces (or a `-wal` made
/// later) is opened again on the next event. Holds the folder grant's
/// security scope while it watches.
final class HistoryFileWatch: Sendable {
    let file: URL
    private let scope: URL?
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.cmuxterm.import-history-sync")
    private let sources = Mutex<[String: any DispatchSourceFileSystemObject]>([:])
    private let ended = Mutex(false)

    init(file: URL, scope: URL?, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        self.scope = scope.flatMap { $0.startAccessingSecurityScopedResource() ? $0 : nil }
        self.onChange = onChange
        queue.async { [self] in armMissing() }
    }

    deinit {
        cancel()
    }

    private var paths: [String] { [file.path, file.path + "-wal", file.deletingLastPathComponent().path] }

    /// Stops every source and gives the folder's scope back; later calls do nothing.
    func cancel() {
        guard !ended.withLock({ ended in defer { ended = true }; return ended }) else { return }
        let open = sources.withLock { sources in
            defer { sources = [:] }
            return Array(sources.values)
        }
        open.forEach { $0.cancel() }
        scope?.stopAccessingSecurityScopedResource()
    }

    /// On `queue`: opens a source for each path that has none (or lost its file).
    private func armMissing() {
        guard !ended.withLock({ $0 }) else { return }
        for path in paths where sources.withLock({ $0[path] == nil }) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                                   queue: queue)
            // wakeup-allow: kqueue file event (no timer); the sync coalesces reads behind a DemandTimer
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    source.cancel()
                    sources.withLock { $0[path] = nil }
                }
                armMissing()
                onChange()
            }
            source.setCancelHandler { close(descriptor) }
            sources.withLock { $0[path] = source }
            source.resume()
        }
    }
}

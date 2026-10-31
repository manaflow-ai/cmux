import CmuxNextCompat
import CmuxNextWakeups
import Darwin
public import Foundation
import os

/// Keep in Sync: watches the history database of every synced source and,
/// ``delay`` after its browser writes it, reads the pages again into that
/// source's saved batch (``ImportedDataStore/replaceHistory(_:with:)``) and
/// hands the new or changed ones to `deliver`, the profile's live history.
/// Re-reading is idempotent: pages merge by URL. Nothing polls: kqueue events
/// on the database, its `-wal` and its folder (each Chromium write makes and
/// deletes `History-journal`), then one coalesced read, skipped when the
/// database files did not change. ``reconcile()`` starts and stops watches to
/// match the store, with one catch-up read per new watch.
public actor ImportHistorySync {
    /// Into a profile's live history: `pages` to merge, `forget` to take out.
    public typealias Deliver = @Sendable (_ profile: String, _ pages: [ImportedHistoryEntry], _ forget: [URL]) async -> Void

    private let store: ImportedDataStore
    private let grants: BrowserFolderGrants?
    private let delay: Duration
    private let limit: Int
    private let deliver: Deliver
    private var watches: [String: HistoryFileWatch] = [:]
    private var timers: [String: DemandTimer] = [:]
    /// Each watched database's files (size and change time) at its last read.
    private var lastRead: [String: [Int64]] = [:]
    /// `browser.import.enabled` off: nothing is watched or read again; the saved pages stay.
    public private(set) var isPaused = false
    /// Runs between a read's save and its hand-on (tests: pause sync in that window).
    var afterSave: (@Sendable () async -> Void)?

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
        guard !isPaused else { return endAll() }
        let records = await store.syncedSources()
        // Paused while the store answered: watch nothing.
        guard !isPaused else { return endAll() }
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

    /// Stops every watch while `paused` (browser import is off) and starts them again after.
    public func setPaused(_ paused: Bool) async {
        guard paused != isPaused else { return }
        isPaused = paused
        await reconcile()
    }

    /// At launch: hands every profile's saved pages to `deliver` (the omnibar
    /// starts with the imported history), then starts the watches.
    public func start(profiles: [String]) async {
        for profile in profiles {
            let pages = await store.batches(profile: profile).flatMap(\.history)
            if !pages.isEmpty { await deliver(profile, pages, []) }
        }
        await reconcile()
    }

    /// Imported pages into `profile`'s live history.
    public func merge(_ pages: [ImportedHistoryEntry], into profile: String) async {
        if !pages.isEmpty { await deliver(profile, pages, []) }
    }

    /// Saves one import batch and returns it as saved (less pages a Clear History
    /// removed); a source the re-import moved to another profile leaves the old one
    /// (its imported bookmarks emptied, its pages taken out).
    @discardableResult
    public func save(_ batch: ImportBatch, bookmarks: (any ImportedBookmarkSink)?) async throws -> ImportBatch {
        let (saved, displaced) = try await store.save(batch)
        guard let displaced else { return saved }
        if !displaced.bookmarks.isEmpty { try await bookmarks?.replaceImportedBookmarks([], source: displaced.source) }
        await deliver(displaced.source.targetProfileID, [], displaced.history.map(\.url))
        return saved
    }

    /// Clear History: the saved imported pages of `profile` (nil: every
    /// profile) from `since` (nil: all) go, and later reads leave that time out.
    public func forget(profile: String?, since: Date?) async {
        do {
            try await store.forgetHistory(profile: profile, since: since)
        } catch {
            Self.logForgetFailure("clear history", error)
        }
    }

    /// Remove from History of one page in `profile`: its saved imported copy goes and stays out.
    public func forgetPage(_ url: URL, profile: String) async {
        do { try await store.forgetPage(url, profile: profile) } catch { Self.logForgetFailure("remove page", error) }
    }

    /// Remove Site: every profile's saved imported pages of `host` go and stay out.
    public func forgetSite(host: String) async {
        do { try await store.forgetSite(host: host) } catch { Self.logForgetFailure("remove site", error) }
    }

    /// The live history changed either way; the saved imported pages would come back at launch.
    private static func logForgetFailure(_ what: String, _ error: any Error) {
        Logger(subsystem: "com.cmuxterm.app.next", category: "browser-import")
            .error("\(what, privacy: .public): saving the imported pages failed: \(String(describing: error), privacy: .public)")
    }

    /// Remove Imported Data: deletes what every import saved into `profile`,
    /// stops its sync, takes its bookmarks out of the bookmarks model and, with
    /// `forgetPages`, its pages out of the profile's live history (not for a
    /// profile being deleted). Returns what went. Sign-ins and passwords stay:
    /// they are in the profile's own stores.
    public func removeImported(profile: String, bookmarks: (any ImportedBookmarkSink)?, forgetPages: Bool = true) async throws -> ImportCounts {
        let removed = try await store.removeImported(profile: profile)
        await reconcile()
        for batch in removed where !batch.bookmarks.isEmpty {
            try await bookmarks?.replaceImportedBookmarks([], source: batch.source)
        }
        if forgetPages { await deliver(profile, [], removed.flatMap(\.history).map(\.url)) }
        return removed.reduce(ImportCounts()) { $0 + ImportCounts(bookmarks: $1.bookmarks.count, history: $1.history.count, openTabs: $1.openTabs.count) }
    }

    /// Stops every watch (the app is quitting, or the store went away).
    public func stop() {
        for key in watches.keys { end(key) }
    }

    private func endAll() {
        for key in Array(watches.keys) { end(key) }
    }

    private func end(_ key: String) {
        watches.removeValue(forKey: key)?.cancel()
        timers.removeValue(forKey: key)?.cancel()
        lastRead[key] = nil
    }

    /// A write arrived: one read `delay` later, however many writes follow.
    private func changed(_ key: String) {
        guard watches[key] != nil else { return }
        let timer = timers[key] ?? DemandTimer(owner: "ImportHistorySync")
        timers[key] = timer
        timer.scheduleIfIdle(after: delay) { [weak self] in await self?.refresh(key) }
    }

    /// Reads the source's pages again when its database changed and hands on
    /// what is new; a source that went away or no longer reads is left as it was.
    func refresh(_ key: String) async {
        guard let watch = watches[key] else { return }
        // A Preferences or Cookies write also wakes the folder watch: nothing to read then.
        let stamp = HistoryFileWatch.stamp(watch.file)
        guard stamp != lastRead[key], let record = await store.syncedSources().first(where: { $0.sourceKey == key }) else { return }
        // Paused (browser import turned off) or rewatched while the store answered: read nothing.
        guard isCurrent(watch, key) else { return }
        guard let pages = try? BrowserImporter.readHistory(record.browser.family, file: watch.file, limit: limit),
              let saved = try? await store.replaceHistory(key, with: pages) else { return }
        await afterSave?()
        // Only a watch still current records the read: paused or rewatched meanwhile, the next
        // watch's catch-up read must not take this stamp as already read.
        if isCurrent(watch, key) { lastRead[key] = stamp }
        // What was saved is handed on either way: the store has it now, so no later read reports
        // it as new, and the omnibar would never see it.
        if !saved.changed.isEmpty { await deliver(saved.record.targetProfileID, saved.changed, []) }
    }

    /// `watch` is still the one for `key` and sync is not paused.
    func setAfterSave(_ hook: (@Sendable () async -> Void)?) {
        afterSave = hook
    }

    private func isCurrent(_ watch: HistoryFileWatch, _ key: String) -> Bool {
        !isPaused && watches[key] === watch
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
    /// The open sources by path; nil once cancelled, so a re-arm racing `cancel` opens nothing.
    private let sources = Mutex<[String: any DispatchSourceFileSystemObject]?>([:])

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

    /// Size and change time of the database, its `-wal` and `-journal`: equal stamps, nothing to read.
    static func stamp(_ file: URL) -> [Int64] {
        [file.path, file.path + "-wal", file.path + "-journal"].flatMap { path -> [Int64] in
            var info = stat()
            guard stat(path, &info) == 0 else { return [-1, -1] }
            return [Int64(info.st_size), Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)]
        }
    }

    /// Stops every source and gives the folder's scope back; later calls do nothing.
    func cancel() {
        guard let open = sources.withLock({ sources in defer { sources = nil }; return sources }) else { return }
        open.values.forEach { $0.cancel() }
        scope?.stopAccessingSecurityScopedResource()
    }

    /// On `queue`: opens a source for each path that has none (or lost its file).
    private func armMissing() {
        for path in paths where sources.withLock({ $0.map { $0[path] == nil } ?? false }) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                                   queue: queue)
            // wakeup-allow: kqueue file event (no timer); the sync coalesces reads behind a DemandTimer
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    source.cancel()
                    sources.withLock { $0?[path] = nil }
                }
                armMissing()
                onChange()
            }
            source.setCancelHandler { close(descriptor) }
            // Stored only while the watch is live; cancelled already, it closes again at once.
            let stored = sources.withLock { sources -> Bool in
                guard sources != nil else { return false }
                sources?[path] = source
                return true
            }
            source.resume()
            if !stored { source.cancel() }
        }
    }
}

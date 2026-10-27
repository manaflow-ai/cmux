public import CmuxNextFileGrid
public import CmuxNextFiles
public import CmuxNextWakeups
public import Foundation
public import Observation

/// The Screenshots pane's state: its folders, the merged newest-first
/// listing of every folder, and the source filter and search text.
///
/// It reads each source once off the main actor through CmuxNextFiles
/// (``ScreenshotFolderReader``), then keeps the listing live with one
/// CmuxNextFiles ``FolderWatching`` stream per folder it read (the source's
/// folder and every subfolder its rule entered): a changed file is looked at
/// alone (a new screenshot is one `lstat`, not a relist); a new or removed
/// subfolder, a burst or lost events relist that source only. Nothing polls.
/// R-hop: a source's read runs off the main actor and lands as one visible task on the app's scheduler.
///
/// ```swift
/// let model = ScreenshotsModel(mainWork: mainWork)
/// model.setSources(detector.detect(findTools: true, extraFolders: []))
/// // model.visibleItems: newest first
/// ```
@MainActor
@Observable
public final class ScreenshotsModel {
    /// The folders shown, in menu order.
    public private(set) var sources: [ScreenshotSource] = []
    /// Every listed file of every folder, newest first.
    public private(set) var listing = ScreenshotListing()
    /// Folders that could not be read (missing permission, removed).
    public private(set) var unreadableSourceIDs: Set<String> = []
    /// The source the grid shows, nil for all.
    public var selectedSourceID: String?
    /// Filters by file name.
    public var query = ""

    @ObservationIgnored private let reader: ScreenshotFolderReader
    @ObservationIgnored private let watcher: any FolderWatching
    @ObservationIgnored private var scans: [String: Task<Void, Never>] = [:]
    /// The read each source waits on, by source id: a finished read of another generation lands nothing.
    @ObservationIgnored private var scanGenerations: [String: UInt64] = [:]
    @ObservationIgnored private var scanGeneration: UInt64 = 0
    /// The folders each source's last read covered, by source id.
    @ObservationIgnored private var foldersBySource: [String: [String]] = [:]
    /// One watch per folder path.
    @ObservationIgnored private var watches: [String: Task<Void, Never>] = [:]
    /// Above this many changed names in one batch, the source is read again.
    @ObservationIgnored private let rescanThreshold = 128
    /// The app's main-thread scheduler: each finished read lands on it.
    @ObservationIgnored private let mainWork: MainWorkScheduler

    /// Makes a model.
    ///
    /// - Parameters:
    ///   - reader: reads folders (default: the disk through CmuxNextFiles).
    ///   - watcher: reports changes (default: CmuxNextFiles' FSEvents ``FolderWatcher``).
    ///   - mainWork: the app's one main-thread scheduler.
    public init(reader: ScreenshotFolderReader = ScreenshotFolderReader(), watcher: any FolderWatching = FolderWatcher(),
                mainWork: MainWorkScheduler) {
        self.reader = reader
        self.watcher = watcher
        self.mainWork = mainWork
    }

    /// The owner of a finished read's task in the board and the wakeup ledger.
    static let readOwner = "ScreenshotsModel.read"

    /// The files the grid shows: the selected source's (or all), matching the search, newest first.
    public var visibleItems: [FileGridItem] {
        listing.filtered(query: query, sources: selectedSourceID.map { [$0] })
    }

    /// Where a drop is saved: the selected source when it takes drops, else the first that does
    /// (the macOS screenshot folder).
    public var dropDestination: URL? {
        if let selectedSourceID, let selected = sources.first(where: { $0.id == selectedSourceID }), selected.acceptsDrops {
            return selected.folder
        }
        return sources.first(where: \.acceptsDrops)?.folder
    }

    /// The folder paths watched now (each source's folder and the subfolders it entered).
    var watchedFolders: Set<String> { Set(watches.keys) }

    /// Shows these folders: reads the new or changed ones, drops the gone ones, and watches them.
    /// The same sources again change nothing.
    ///
    /// - Parameter newSources: the folders, in menu order.
    public func setSources(_ newSources: [ScreenshotSource]) {
        guard newSources != sources else { return }
        let old = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(newSources.map(\.id))
        for source in sources where !kept.contains(source.id) {
            scans.removeValue(forKey: source.id)?.cancel()
            scanGenerations.removeValue(forKey: source.id)
            foldersBySource.removeValue(forKey: source.id)
            listing.removeSource(source.id)
            unreadableSourceIDs.remove(source.id)
        }
        sources = newSources
        if let selectedSourceID, !kept.contains(selectedSourceID) { self.selectedSourceID = nil }
        for source in newSources where old[source.id] != source {
            foldersBySource[source.id] = [source.folder.path]
            scheduleRescan(source)
        }
        syncWatches()
    }

    /// Reads every folder again and returns when all are read.
    public func refresh() async {
        for source in sources { scheduleRescan(source) }
        // Each read clears its own entry when done (a newer read replaces a cancelled one).
        while let pending = scans.values.first { await pending.value }
    }

    /// Stops every watch and every read in flight (the tab closed).
    public func stop() {
        for task in watches.values { task.cancel() }
        watches.removeAll()
        for task in scans.values { task.cancel() }
        scans.removeAll()
        scanGenerations.removeAll()
    }

    /// Adds files this pane just saved (a drop) without waiting for the watch.
    ///
    /// - Parameter urls: the new files.
    public func noteSaved(_ urls: [URL]) async {
        for url in urls {
            guard let source = source(containing: url.path), let item = await reader.item(at: url, in: source) else { continue }
            listing.upsert(item)
        }
    }

    /// Applies one change the watch of `folder` reported: each changed file is looked at alone;
    /// a subfolder that appeared or went, lost events or a burst read the source again.
    ///
    /// - Parameters:
    ///   - change: what CmuxNextFiles' watcher reported.
    ///   - folder: the watched folder.
    public func apply(_ change: FolderChange, in folder: URL) async {
        guard let source = source(containing: folder.path) else { return }
        guard case .items(let names) = change, names.count <= rescanThreshold else { return scheduleRescan(source) }
        let known = Set(foldersBySource[source.id] ?? [])
        let depth = Self.depth(of: folder.path, below: source.folder.path)
        var relist = false
        for name in Set(names) {
            let url = folder.appendingPathComponent(name)
            if known.contains(url.path) {
                relist = true
                continue
            }
            guard let entry = await reader.entry(at: url) else {
                listing.remove(path: url.path)
                continue
            }
            if ScreenshotFolderReader.enters(entry, depth: depth, rule: source.rule) {
                relist = true
            } else if let item = ScreenshotFolderReader.item(entry, in: source), Self.isListed(url.path, in: source) {
                listing.upsert(item)
            } else {
                listing.remove(path: url.path)
            }
        }
        if relist { scheduleRescan(source) }
    }

    /// Whether `path` sits where `source`'s rule lists files (its depth and folder prefix).
    static func isListed(_ path: String, in source: ScreenshotSource) -> Bool {
        let root = source.folder.path
        guard path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard parts.count >= 1, parts.count - 1 <= source.rule.depth else { return false }
        return parts.dropLast().allSatisfy { source.rule.entersFolder(named: $0) }
    }

    /// How many folder levels `path` is below `root` (0 for the root itself).
    private static func depth(of path: String, below root: String) -> Int {
        path == root ? 0 : path.dropFirst(root.count + 1).split(separator: "/").count
    }

    /// The source whose folder holds `path` (the deepest one).
    private func source(containing path: String) -> ScreenshotSource? {
        sources.filter { path == $0.folder.path || path.hasPrefix($0.folder.path + "/") }
            .max { $0.folder.path.count < $1.folder.path.count }
    }

    private func scheduleRescan(_ source: ScreenshotSource) {
        scans[source.id]?.cancel()
        scanGeneration &+= 1
        scanGenerations[source.id] = scanGeneration
        let reader = reader, mainWork = mainWork, owner = Self.readOwner, generation = scanGeneration
        // task-owner: `scans[source.id]`; a newer read of the source or stop() cancels it
        scans[source.id] = Task { @concurrent in
            let result = await reader.read(source)
            guard !Task.isCancelled else { return }
            // R-hop: the listing lands as one visible task (the grid shows it); refresh() awaits it.
            await mainWork.apply(.visible, owner: owner) { [weak self] in self?.land(result, of: source, generation: generation) }
        }
    }

    /// Lands `source`'s finished read of `generation`: its files, the folders to watch, and whether it could be read.
    /// A read that a newer one or ``stop()`` replaced while its task waited lands nothing.
    private func land(_ result: ScreenshotFolderReader.Result, of source: ScreenshotSource, generation: UInt64) {
        guard scanGenerations[source.id] == generation, sources.contains(where: { $0.id == source.id }) else { return }
        scanGenerations[source.id] = nil
        listing.replace(source: source.id, with: result.items)
        foldersBySource[source.id] = result.readable ? result.folders : [source.folder.path]
        if result.readable { unreadableSourceIDs.remove(source.id) } else { unreadableSourceIDs.insert(source.id) }
        syncWatches()
        scans[source.id] = nil
    }

    /// Watches exactly the folders the sources' last reads covered.
    private func syncWatches() {
        let wanted = Set(sources.flatMap { foldersBySource[$0.id] ?? [$0.folder.path] })
        for (path, task) in watches where !wanted.contains(path) {
            task.cancel()
            watches[path] = nil
        }
        for path in wanted where watches[path] == nil {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let stream = watcher.changes(in: folder)
            // task-owner: `watches[path]`; cancelled when the folder leaves the sources or on stop()
            // main-hop-allow: one FSEvents batch at a time, in order: apply is the model's main-actor change (each changed name is one off-main `lstat` through the reader)
            watches[path] = Task { [weak self] in
                for await change in stream {
                    guard let self else { return }
                    await self.apply(change, in: folder)
                }
            }
        }
    }
}

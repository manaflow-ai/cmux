public import CmuxNextFileGrid
public import Foundation
public import Observation

/// The Screenshots pane's state: its folders, the merged newest-first
/// listing of every folder, and the source filter and search text.
///
/// It lists each folder once off the main actor, then keeps the listing live
/// from one FSEvents watch over all folders: a changed file is looked at
/// alone (a new screenshot is one `stat`, not a relist); a changed folder,
/// a burst or lost events relist that folder only. Nothing polls.
///
/// ```swift
/// let model = ScreenshotsModel()
/// model.setSources(detector.detect(findTools: true, extraFolders: []))
/// // model.visibleItems: newest first
/// ```
@MainActor
@Observable
public final class ScreenshotsModel {
    /// The folders shown, in menu order.
    public private(set) var sources: [ScreenshotSource] = []
    /// Every listed file of every folder, newest first.
    public private(set) var listing = FileGridListing()
    /// Folders that could not be read (missing permission, removed).
    public private(set) var unreadableSourceIDs: Set<String> = []
    /// The source the grid shows, nil for all.
    public var selectedSourceID: String?
    /// Filters by file name.
    public var query = ""

    @ObservationIgnored private let scanner: DirectoryScanner
    @ObservationIgnored private let watcher: any DirectoryWatching
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var scans: [String: Task<Void, Never>] = [:]
    /// Above this many changes for one folder in one batch, the folder is listed again.
    @ObservationIgnored private let rescanThreshold = 128

    /// Makes a model.
    ///
    /// - Parameters:
    ///   - scanner: lists folders (default: the disk).
    ///   - watcher: reports changes (default: FSEvents).
    public init(scanner: DirectoryScanner = DirectoryScanner(), watcher: any DirectoryWatching = DirectoryWatcher()) {
        self.scanner = scanner
        self.watcher = watcher
    }

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

    /// Shows these folders: lists the new or changed ones, drops the gone ones, and watches them all.
    /// The same sources again change nothing.
    ///
    /// - Parameter newSources: the folders, in menu order.
    public func setSources(_ newSources: [ScreenshotSource]) {
        guard newSources != sources else { return }
        let old = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(newSources.map(\.id))
        for source in sources where !kept.contains(source.id) {
            scans.removeValue(forKey: source.id)?.cancel()
            listing.removeSource(source.id)
            unreadableSourceIDs.remove(source.id)
        }
        sources = newSources
        if let selectedSourceID, !kept.contains(selectedSourceID) { self.selectedSourceID = nil }
        for source in newSources where old[source.id] != source { scheduleRescan(source) }
        watch()
    }

    /// Lists every folder again and returns when all are listed.
    public func refresh() async {
        for source in sources { scheduleRescan(source) }
        for task in Array(scans.values) { await task.value }
    }

    /// Stops the watch and every listing in flight (the tab closed).
    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        for task in scans.values { task.cancel() }
        scans.removeAll()
    }

    /// Adds files this pane just saved (a drop) without waiting for the watch.
    ///
    /// - Parameter urls: the new files.
    public func noteSaved(_ urls: [URL]) async {
        for url in urls {
            guard let source = source(containing: url.path), let item = await scanner.item(at: url, sourceID: source.id, rule: source.rule)
            else { continue }
            listing.upsert(item)
        }
    }

    /// Applies one batch of watch events: each changed file is looked at alone; a changed folder,
    /// lost events or a burst relist the folder.
    ///
    /// - Parameter events: what FSEvents reported.
    public func apply(_ events: [DirectoryWatcherEvent]) async {
        var files: [String: [String]] = [:]
        var relist: Set<String> = []
        for event in events {
            guard let source = source(containing: event.path) else { continue }
            if event.mustRescan || event.isDirectory || event.path == source.folder.path {
                relist.insert(source.id)
            } else {
                files[source.id, default: []].append(event.path)
            }
        }
        for (id, paths) in files where paths.count > rescanThreshold { relist.insert(id) }
        for source in sources where relist.contains(source.id) { scheduleRescan(source) }
        for source in sources {
            guard !relist.contains(source.id), let paths = files[source.id] else { continue }
            for path in Set(paths) where Self.isListed(path, in: source) {
                if let item = await scanner.item(at: URL(fileURLWithPath: path), sourceID: source.id, rule: source.rule) {
                    listing.upsert(item)
                } else {
                    listing.remove(path: path)
                }
            }
        }
    }

    /// Whether `path` sits where `source`'s rule lists files (its depth and folder prefix).
    static func isListed(_ path: String, in source: ScreenshotSource) -> Bool {
        let root = source.folder.path
        guard path.hasPrefix(root + "/") else { return false }
        let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        guard parts.count >= 1, parts.count - 1 <= source.rule.depth else { return false }
        return parts.dropLast().allSatisfy { source.rule.entersFolder(named: $0) }
    }

    /// The source whose folder holds `path` (the deepest one).
    private func source(containing path: String) -> ScreenshotSource? {
        sources.filter { path == $0.folder.path || path.hasPrefix($0.folder.path + "/") }
            .max { $0.folder.path.count < $1.folder.path.count }
    }

    private func scheduleRescan(_ source: ScreenshotSource) {
        scans[source.id]?.cancel()
        let scanner = scanner
        scans[source.id] = Task { [weak self] in
            let result = await scanner.scan(source.folder, sourceID: source.id, rule: source.rule)
            guard !Task.isCancelled, let self, self.sources.contains(where: { $0.id == source.id }) else { return }
            self.listing.replace(source: source.id, with: result.items)
            if result.readable { self.unreadableSourceIDs.remove(source.id) } else { self.unreadableSourceIDs.insert(source.id) }
        }
    }

    private func watch() {
        watchTask?.cancel()
        let stream = watcher.events(for: sources.map(\.folder.path))
        watchTask = Task { [weak self] in
            for await batch in stream {
                guard let self else { return }
                await self.apply(batch)
            }
        }
    }
}

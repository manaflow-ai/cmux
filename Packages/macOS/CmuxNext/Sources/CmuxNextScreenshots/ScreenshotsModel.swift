import CCmuxScreenshots
public import CmuxNextFileGrid
public import CmuxNextFiles
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
    /// One watch per folder path.
    @ObservationIgnored private var watches: [String: Task<Void, Never>] = [:]
    /// The sources' bookkeeping (cmux-screenshots `pane.rs`): which folders each read covered, which
    /// failed, what to watch and what a watch event means.
    @ObservationIgnored private let pane: RustHandle

    /// Whether the folders are read and watched (``startListing()``).
    public private(set) var isListing: Bool

    /// Whether the page lists and every folder's last read failed (missing permission, or removed).
    public private(set) var accessMissing = false

    /// Makes a model.
    ///
    /// - Parameters:
    ///   - reader: reads folders (default: the disk through CmuxNextFiles).
    ///   - watcher: reports changes (default: CmuxNextFiles' FSEvents ``FolderWatcher``).
    ///   - listsAtOnce: read and watch the folders as soon as they are set; off (the default), nothing is read
    ///     or watched until ``startListing()`` (macOS guards ~/Desktop, the default screenshot folder).
    public init(reader: ScreenshotFolderReader = ScreenshotFolderReader(), watcher: any FolderWatching = FolderWatcher(),
                listsAtOnce: Bool = false) {
        self.reader = reader
        self.watcher = watcher
        isListing = listsAtOnce
        pane = RustHandle(cmux_screenshots_pane_new(listsAtOnce)) { cmux_screenshots_pane_free($0) }
    }

    /// Reads and watches the folders from now on (the page is on screen).
    public func startListing() {
        guard cmux_screenshots_pane_start(pane.pointer) else { return }
        isListing = true
        for source in sources { scheduleRescan(source) }
        applyState()
    }

    /// Stops reading and watching and drops the listing until ``startListing()`` (access was taken back).
    public func pauseListing() {
        stop()
        cmux_screenshots_pane_pause(pane.pointer)
        isListing = false
        listing = ScreenshotListing()
        applyState()
    }

    /// The files the grid shows: the selected source's (or all), matching the search, newest first.
    public var visibleItems: [FileGridItem] {
        listing.filtered(query: query, sources: selectedSourceID.map { [$0] })
    }

    /// Where a drop is saved: the selected source when it takes drops, else the first that does
    /// (the macOS screenshot folder).
    public var dropDestination: URL? {
        let id = ScreenshotsFFI.take(ScreenshotsFFI.bytes(selectedSourceID ?? "") { cmux_screenshots_pane_drop_source(pane.pointer, $0, $1) })
        return sources.first { $0.id == id }?.folder
    }

    /// The folder paths watched now (each source's folder and the subfolders it entered).
    var watchedFolders: Set<String> { Set(watches.keys) }

    /// Shows these folders: reads the new or changed ones, drops the gone ones, and watches them.
    /// The same sources again change nothing.
    ///
    /// - Parameter newSources: the folders, in menu order.
    public func setSources(_ newSources: [ScreenshotSource]) {
        guard newSources != sources else { return }
        let json = ScreenshotsFFI.json(newSources.map {
            ["id": $0.id, "label": $0.label, "folder": $0.folder.path, "acceptsDrops": $0.acceptsDrops, "rule": (try? JSONSerialization.jsonObject(with: Data($0.rule.json.utf8))) ?? [:]] as [String: Any]
        })
        let plan = ScreenshotsFFI.object(ScreenshotsFFI.bytes(json) { cmux_screenshots_pane_set_sources(pane.pointer, $0, $1) })
        for id in plan["removed"] as? [String] ?? [] {
            scans.removeValue(forKey: id)?.cancel()
            listing.removeSource(id)
        }
        sources = newSources
        if let selectedSourceID, !newSources.contains(where: { $0.id == selectedSourceID }) { self.selectedSourceID = nil }
        let read = Set(plan["read"] as? [String] ?? [])
        for source in newSources where read.contains(source.id) { scheduleRescan(source) }
        applyState()
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
        let names: String? = if case .items(let items) = change { ScreenshotsFFI.json(items) } else { nil }
        let plan = ScreenshotsFFI.object(ScreenshotsFFI.strings([folder.path, names ?? ""]) { text in
            cmux_screenshots_pane_change(pane.pointer, text[0].bytes, text[0].count, names == nil ? nil : text[1].bytes, text[1].count)
        })
        if let id = plan["rescan"] as? String, let source = sources.first(where: { $0.id == id }) { return scheduleRescan(source) }
        guard let id = plan["source"] as? String, let source = sources.first(where: { $0.id == id }) else { return }
        var relist = plan["relist"] as? Bool ?? false
        for path in plan["paths"] as? [String] ?? [] {
            let entry = await reader.entry(at: URL(fileURLWithPath: path))
            switch entryAction(source: id, folder: folder.path, path: path, entry: entry) {
            case 1: relist = true
            case 2:
                if let entry, let item = ScreenshotFolderReader.item(entry, in: source) { listing.upsert(item) } else { listing.remove(path: path) }
            default: listing.remove(path: path)
            }
        }
        if relist { scheduleRescan(source) }
    }

    /// What a looked-at path does (0 remove, 1 read the source again, 2 list it).
    private func entryAction(source id: String, folder: String, path: String, entry: FileEntry?) -> UInt32 {
        ScreenshotsFFI.strings([id, folder, path, entry?.name ?? ""]) { parts in
            var raw = CmuxScreenshotsEntry(kind: entry.map { ScreenshotsFFI.raw($0.kind) } ?? 0, hidden: entry?.isHidden ?? false,
                                           name: parts[3].bytes, name_len: parts[3].count,
                                           system_kind: ScreenshotsFFI.systemKind(ofFileNamed: entry?.name ?? ""),
                                           modified: entry?.modified.timeIntervalSince1970 ?? 0)
            return withUnsafePointer(to: &raw) {
                cmux_screenshots_pane_entry_action(pane.pointer, parts[0].bytes, parts[0].count, parts[1].bytes, parts[1].count,
                                                   parts[2].bytes, parts[2].count, entry == nil ? nil : $0)
            }
        }
    }

    /// The source whose folder holds `path` (the deepest one).
    private func source(containing path: String) -> ScreenshotSource? {
        let id = ScreenshotsFFI.take(ScreenshotsFFI.bytes(path) { cmux_screenshots_pane_source_containing(pane.pointer, $0, $1) })
        return sources.first { $0.id == id }
    }

    private func scheduleRescan(_ source: ScreenshotSource) {
        guard isListing else { return }
        scans[source.id]?.cancel()
        let reader = reader
        // task-owner: `scans[source.id]`; a newer read of the source or stop() cancels it
        scans[source.id] = Task { [weak self] in
            let result = await reader.read(source)
            guard !Task.isCancelled, let self else { return }
            let taken = ScreenshotsFFI.strings([source.id, ScreenshotsFFI.json(result.folders)]) { parts in
                cmux_screenshots_pane_read_done(self.pane.pointer, parts[0].bytes, parts[0].count, result.readable, parts[1].bytes, parts[1].count)
            }
            guard taken else { return }
            self.listing.replace(source: source.id, with: result.items)
            self.applyState()
            self.scans[source.id] = nil
        }
    }

    /// Takes the pane's failed reads and watches exactly the folders it names.
    private func applyState() {
        let state = ScreenshotsFFI.object(cmux_screenshots_pane_state(pane.pointer))
        let unreadable = Set(state["unreadable"] as? [String] ?? [])
        if unreadable != unreadableSourceIDs { unreadableSourceIDs = unreadable }
        let missing = state["accessMissing"] as? Bool ?? false
        if missing != accessMissing { accessMissing = missing }
        guard let watched = state["watched"] as? [String] else { return }
        let wanted = Set(watched)
        for (path, task) in watches where !wanted.contains(path) {
            task.cancel()
            watches[path] = nil
        }
        for path in wanted where watches[path] == nil {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let stream = watcher.changes(in: folder)
            // task-owner: `watches[path]`; cancelled when the folder leaves the sources or on stop()
            watches[path] = Task { [weak self] in
                for await change in stream {
                    guard let self else { return }
                    await self.apply(change, in: folder)
                }
            }
        }
    }
}

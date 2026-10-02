import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDaemon
import Foundation
import Observation
import os

/// Bookmarks of every browser profile (plans/cmux-next/bookmarks.md): the
/// trees, where they are stored, and the fan-out to the omnibar stars,
/// bookmarks bars and manager pages.
///
/// Storage: the home daemon's `bookmarks-v1` table when it serves it, else
/// `<Application Support>/<bundle id>/BrowserProfiles/bookmarks.json`. An
/// edit is applied to the local tree first (the same `BookmarkTree.apply`
/// rules the daemon enforces), then written; with the daemon, its
/// `bookmarks-changed` event refetches the profile and replaces the tree.
@Observable @MainActor
final class BookmarkService {
    /// Each browser profile's tree (wire id: `default` or a UUID).
    var trees: [String: BookmarkTree] = [:]
    /// Bumped on every change, so views that read many profiles can observe one value.
    private(set) var generation = 0
    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored var file: BookmarkFileStore?
    @ObservationIgnored var directory: URL?
    @ObservationIgnored var importStore: ImportedDataStore?
    /// Profiles whose daemon tree was fetched on this connection.
    @ObservationIgnored var fetched: Set<String> = []
    @ObservationIgnored var fetching: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var fileTrees: [String: [BookmarkNode]] = [:]
    @ObservationIgnored var fileLoaded = false
    @ObservationIgnored var saving: Task<Void, Never>?
    @ObservationIgnored var homeObservation: Task<Void, Never>?
    @ObservationIgnored var barObservation: Task<Void, Never>?
    @ObservationIgnored var migrating = false
    /// The folder each profile's last bookmark went to (Chrome remembers it).
    @ObservationIgnored var lastFolder: [String: String] = [:]
    /// Live browser chromes, by tab key, for the star and bar fan-out.
    @ObservationIgnored var chromes: [String: WeakChrome] = [:]
    @ObservationIgnored var showsBar = false
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "bookmarks")

    final class WeakChrome {
        weak var entry: BrowserEntry?
        let bar: BookmarksBarView
        let source: BookmarkBarSourceAdapter
        init(entry: BrowserEntry, bar: BookmarksBarView, source: BookmarkBarSourceAdapter) {
            self.entry = entry
            self.bar = bar
            self.source = source
        }
    }

    init(services: AppServices) {
        self.services = services
    }

    /// Reads the file, observes the home daemon, and runs the one-time
    /// migrations (file to daemon, earlier browser imports into bookmarks).
    func start(directory: URL, importStore: ImportedDataStore?) {
        self.directory = directory
        self.importStore = importStore
        let file = BookmarkFileStore(file: directory.appending(path: "bookmarks.json"))
        self.file = file
        services.importedBookmarkSink = BookmarkImportSink(service: self)
        services.machines.local.store.sideEvents.subscribe { [weak self] event in
            if case .bookmarksChanged(let profile, _) = event { self?.daemonChanged(profile) }
        }
        // task-owner: one-shot launch read of the bookmark file
        Task { [weak self] in
            let loaded = await file.load()
            guard let self else { return }
            fileTrees = loaded
            fileLoaded = true
            if !usesDaemon {
                trees = loaded.mapValues(BookmarkTree.init(ordered:))
                changed(profiles: Set(loaded.keys))
            }
            observeHome()
            await migrateLegacyImports()
        }
    }

    // MARK: Reading

    /// The home daemon serves bookmarks; every read and write goes there.
    var usesDaemon: Bool { services.machines.local.supports(DaemonCapabilities.shared.bookmarks) }

    /// `profile`'s tree; asks the daemon for it the first time.
    func tree(_ profile: String) -> BookmarkTree {
        if usesDaemon, !fetched.contains(profile) { fetch(profile) }
        return trees[profile] ?? BookmarkTree()
    }

    /// The wire id whose bookmarks a tab shows: its browser profile, the
    /// default one for an incognito tab (Chrome shows your bookmarks there).
    func profile(ofTab key: String) -> String {
        let engine = services.browserProfiles.engineProfile(forTab: key)
        if OffTheRecordProfiles.shared.isOffTheRecord(engine) { return BrowserProfileRecord.defaultID }
        return BrowserProfileRecord.wireID(for: engine)
    }

    /// The wire id for an engine profile (a page's `profileID`).
    func profile(of engine: BrowserProfileID) -> String {
        OffTheRecordProfiles.shared.isOffTheRecord(engine) ? BrowserProfileRecord.defaultID : BrowserProfileRecord.wireID(for: engine)
    }

    func isBookmarked(_ url: URL?, profile: String) -> Bool { tree(profile).isBookmarked(url) }

    /// The folder a new bookmark goes to: the last one used, else the bar.
    func defaultFolder(profile: String) -> String {
        if let folder = lastFolder[profile], tree(profile).isContainer(folder) { return folder }
        return BookmarkRoot.bar.rawValue
    }

    // MARK: Writing

    /// Applies `operation` to `profile`'s tree and writes it. Validation
    /// errors throw before anything changes.
    @discardableResult
    func apply(_ operation: BookmarkOperation, profile: String) throws -> BookmarkChange {
        var tree = tree(profile)
        let change = try tree.apply(operation)
        guard !change.isEmpty || isImport(operation) else { return change }
        trees[profile] = tree
        if case .create(let node, _) = operation { lastFolder[profile] = node.parent }
        if usesDaemon {
            send(operation, profile: profile)
        } else {
            saveFile(profile: profile)
        }
        changed(profiles: [profile])
        return change
    }

    /// Marks a bookmark as used now (opened from any bookmark surface).
    func touch(_ id: String, profile: String) {
        try? apply(.update(id: id, lastUsed: .set(Date())), profile: profile)
    }

    private func isImport(_ operation: BookmarkOperation) -> Bool {
        if case .importDrafts = operation { return true }
        return false
    }

    func saveFile(profile: String) {
        guard let file else { return }
        let nodes = trees[profile]?.ordered ?? []
        fileTrees[profile] = nodes
        let previous = saving, logger = logger
        // task-owner: chained single-file saves; each waits for the previous
        saving = Task {
            await previous?.value
            do { try await file.save(profile: profile, nodes: nodes) } catch {
                logger.error("save bookmarks: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits for pending file saves (tests, termination).
    func flush() async { await saving?.value }

    /// Every view of `profiles` redraws (stars, bars, manager pages).
    func changed(profiles: Set<String>) {
        generation &+= 1
        refreshChromes(profiles: profiles)
        services.bookmarkPages.reload(profiles: profiles)
    }

    /// A browser profile was deleted: its bookmarks go too (the daemon
    /// deletes its rows itself).
    func dropProfile(_ profile: String) {
        trees[profile] = nil
        fetched.remove(profile)
        if !usesDaemon, fileTrees[profile] != nil { saveFile(profile: profile) }
    }
}

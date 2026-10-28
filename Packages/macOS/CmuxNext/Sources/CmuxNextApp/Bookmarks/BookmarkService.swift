import struct CmuxSafeConcurrency.OwnerReference
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
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
    @ObservationIgnored private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    var services: AppServices? { servicesReference.resolve() }
    /// The app's machines (``AppServices/machines``): bookmarks live in the home daemon, `machines.local`.
    @ObservationIgnored let machines: MachineRegistry
    /// The app's main-thread scheduler and deadlines (``AppServices/mainWork``, ``AppServices/mainDeadlines``).
    @ObservationIgnored let mainWork: MainWorkScheduler
    @ObservationIgnored let mainDeadlines: MainDeadlineScheduler
    @ObservationIgnored var file: BookmarkFileStore?
    @ObservationIgnored var directory: URL?
    @ObservationIgnored var importStore: ImportedDataStore?
    /// Profiles whose daemon tree was fetched on this connection.
    @ObservationIgnored var fetched: Set<String> = []
    /// Profiles whose tree came from a daemon reply requested after the
    /// home daemon settled (the file copied over), since the last switch.
    @ObservationIgnored var loadedFromDaemon: Set<String> = []
    /// `observeHome` finished its pass for the daemon's current capability.
    @ObservationIgnored var homeSettled = false
    @ObservationIgnored var fetching: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var fileTrees: [String: [BookmarkNode]] = [:]
    @ObservationIgnored var fileLoaded = false
    @ObservationIgnored var saving: Task<Void, Never>?
    @ObservationIgnored var homeObservation: ServiceObservation<ObservationTrigger<Bool>>?
    /// The running switch to or from the daemon's trees; the next one waits for it (``observeHome()``).
    @ObservationIgnored var homeSwitch: Task<Void, Never>?
    /// Bumped by every capability change: a switch step of an older one does nothing.
    @ObservationIgnored var homeGeneration: UInt64 = 0
    /// The switch's copy of the file into the home daemon; nil: ``migrateFileToDaemon()``. A test sets it
    /// to change the capability while a switch copies.
    @ObservationIgnored var homeCopy: (@MainActor () async -> Void)?
    @ObservationIgnored var barObservation: ServiceObservation<Bool>?
    @ObservationIgnored var faviconObservation: ServiceObservation<Int>?
    /// Stored folder icons a bar drew the folder symbol for while they load (``followFolderIcons()``).
    var awaitedFolderIcons: Set<String> = []
    @ObservationIgnored var folderIconObservation: ServiceObservation<Set<String>>?
    /// Each omnibar suggestion engine's bookmark feed, by engine (``BookmarkSuggestionFeed``).
    @ObservationIgnored var suggestionFeeds: [ObjectIdentifier: ServiceObservation<[BookmarkNode]>] = [:]
    @ObservationIgnored var migrating = false
    /// The folder each profile's last bookmark went to, offered for the next one.
    @ObservationIgnored var lastFolder: [String: String] = [:]
    /// Live browser chromes, by tab key, for the star and bar fan-out.
    @ObservationIgnored var chromes: [String: WeakChrome] = [:]
    /// Chromium's bookmark models follow the trees (chrome.bookmarks bridge).
    @ObservationIgnored var chromium: BookmarkChromiumSync?
    @ObservationIgnored var showsBar = false
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "bookmarks")

    final class WeakChrome {
        weak var entry: BrowserEntry?
        let bar: BookmarksBarView
        let source: BookmarkBarSourceAdapter
        /// The tab's visibility node (`TabContentCache.node(for:)`), held so a reload waiting for
        /// the tab to show is not dropped with it.
        let node: VisibilityNode
        init(entry: BrowserEntry, bar: BookmarksBarView, source: BookmarkBarSourceAdapter, node: VisibilityNode) {
            self.entry = entry
            self.bar = bar
            self.source = source
            self.node = node
        }
    }

    init(services: AppServices) {
        servicesReference = OwnerReference(services: services)
        machines = services.machines
        mainWork = services.mainWork
        mainDeadlines = services.mainDeadlines
    }

    /// Reads the file, observes the home daemon, and runs the one-time
    /// migrations (file to daemon, earlier browser imports into bookmarks).
    func start(directory: URL, importStore: ImportedDataStore?) {
        guard let services else { return }
        self.directory = directory
        self.importStore = importStore
        let file = BookmarkFileStore(file: directory.appending(path: "bookmarks.json"))
        self.file = file
        services.importedBookmarkSink = BookmarkImportSink(service: self)
        chromium = BookmarkChromiumSync(service: self)
        services.machines.local.store.sideEvents.subscribe { [weak self] event in
            if case .bookmarksChanged(let profile, _) = event { self?.daemonChanged(profile) }
        }
        let mainWork = services.mainWork, work = services.work
        // task-owner: one-shot launch read of the bookmark file. The file actor reads off main; the trees apply as
        // one posted `visible` task (bars and stars show them), then the legacy imports migrate once.
        Task { @concurrent [weak self] in
            let loaded = await file.load()
            await mainWork.apply(.visible, owner: "BookmarkService.fileLoaded") { [weak self] () -> Void in self?.fileRead(loaded) }
            guard let importStore, let self else { return }
            await self.migrateLegacyImports(store: importStore, directory: directory, mainWork: mainWork, work: work)
        }
    }

    /// The bookmark file's trees are read: they are the truth until the home daemon serves bookmarks.
    private func fileRead(_ loaded: [String: [BookmarkNode]]) {
        fileTrees = loaded
        fileLoaded = true
        if !usesDaemon {
            trees = loaded.mapValues(BookmarkTree.init(ordered:))
            changed(profiles: Set(loaded.keys))
        }
        observeHome()
    }

    // MARK: Reading

    /// The home daemon serves bookmarks; every read and write goes there.
    var usesDaemon: Bool { machines.local.supports(DaemonCapability.bookmarks.rawValue) }

    /// `profile`'s tree; asks the daemon for it the first time.
    func tree(_ profile: String) -> BookmarkTree {
        if usesDaemon, !fetched.contains(profile) { fetch(profile) }
        return trees[profile] ?? BookmarkTree()
    }

    /// The wire id whose bookmarks a tab shows: its browser profile, the
    /// default one for an incognito tab, so incognito shows your bookmarks.
    func profile(ofTab key: String) -> String {
        guard let services else { return BrowserProfileRecord.defaultID }
        let engine = services.browserProfiles.engineProfile(forTab: key)
        if services.browserStores.offTheRecord.isOffTheRecord(engine) { return BrowserProfileRecord.defaultID }
        return BrowserProfileRecord.wireID(for: engine)
    }

    /// The wire id for an engine profile (a page's `profileID`).
    func profile(of engine: BrowserProfileID) -> String {
        services?.browserStores.offTheRecord.isOffTheRecord(engine) == true ? BrowserProfileRecord.defaultID : BrowserProfileRecord.wireID(for: engine)
    }

    func isBookmarked(_ url: URL?, profile: String) -> Bool { tree(profile).isBookmarked(url) }

    /// `profile`'s tree is the stored one, not an empty placeholder: with the
    /// daemon, once its reply arrived; with the file, once the file is read
    /// and the home daemon is known not to serve bookmarks (it answered
    /// without the capability, or is unavailable), so the file is the truth.
    func isLoaded(_ profile: String) -> Bool {
        guard let services else { return false }
        if usesDaemon { return loadedFromDaemon.contains(profile) }
        let home = services.machines.local
        return fileLoaded && (home.store.identity != nil || home.startup != .connecting)
    }

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
        // task-owner: chained single-file saves; each waits for the previous. Off main: the file actor writes,
        // and nothing applies on main after it.
        saving = Task { @concurrent in
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
        guard let services else { return }
        generation &+= 1
        refreshChromes(profiles: profiles)
        services.bookmarkPages.reload(profiles: profiles)
        chromium?.treesChanged(profiles)
    }

    /// A browser profile was deleted: its bookmarks go too (the daemon
    /// deletes its rows itself).
    func dropProfile(_ profile: String) {
        trees[profile] = nil
        fetched.remove(profile)
        loadedFromDaemon.remove(profile)
        if !usesDaemon, fileTrees[profile] != nil { saveFile(profile: profile) }
    }
}

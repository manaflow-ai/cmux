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
/// Storage: the home daemon's `bookmarks-v1` table, the one writer. An edit
/// is applied to the local tree first (the same `BookmarkTree.apply` rules
/// the daemon enforces), then sent; the daemon's `bookmarks-changed` event
/// refetches the profile and replaces the tree. Until the daemon serves
/// bookmarks, an edit is refused. A `bookmarks.json` left by an older build
/// (`<Application Support>/<bundle id>/BrowserProfiles/`) is copied into the
/// daemon once and then deleted (``migrateFileToDaemon()``).
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
    /// Profiles whose tree came from a daemon reply requested after the
    /// home daemon settled (the file copied over), since the last switch.
    @ObservationIgnored var loadedFromDaemon: Set<String> = []
    /// `observeHome` finished its pass for the daemon's current capability.
    @ObservationIgnored var homeSettled = false
    @ObservationIgnored var fetching: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var homeObservation: Task<Void, Never>?
    @ObservationIgnored var barObservation: Task<Void, Never>?
    /// Stored folder icons a bar drew the folder symbol for while they load (``followFolderIcons()``).
    var awaitedFolderIcons: Set<String> = []
    @ObservationIgnored var folderIconObservation: Task<Void, Never>?
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
        init(entry: BrowserEntry, bar: BookmarksBarView) {
            self.entry = entry
            self.bar = bar
        }
    }

    init(services: AppServices) {
        self.services = services
    }

    /// Observes the home daemon, which runs the one-time migrations once it
    /// serves bookmarks (an older build's file, earlier browser imports).
    func start(directory: URL, importStore: ImportedDataStore?) {
        self.directory = directory
        self.importStore = importStore
        let file = BookmarkFileStore(file: directory.appending(path: "bookmarks.json"))
        self.file = file
        services.importedBookmarkSink = BookmarkImportSink(service: self)
        chromium = BookmarkChromiumSync(service: self)
        services.machines.local.store.sideEvents.subscribe { [weak self] event in
            if case .bookmarksChanged(let profile, _) = event { self?.daemonChanged(profile) }
        }
        observeHome()
    }

    // MARK: Reading

    /// The home daemon serves bookmarks; every read and write goes there.
    var usesDaemon: Bool { services.machines.local.supports(DaemonCapability.bookmarks.rawValue) }

    /// `profile`'s tree; asks the daemon for it the first time.
    func tree(_ profile: String) -> BookmarkTree {
        if usesDaemon, !fetched.contains(profile) { fetch(profile) }
        return trees[profile] ?? BookmarkTree()
    }

    /// The wire id whose bookmarks a tab shows: its browser profile, the
    /// default one for an incognito tab, so incognito shows your bookmarks.
    func profile(ofTab key: String) -> String {
        let engine = services.browserProfiles.engineProfile(forTab: key)
        if services.browserStores.offTheRecord.isOffTheRecord(engine) { return BrowserProfileRecord.defaultID }
        return BrowserProfileRecord.wireID(for: engine)
    }

    /// The wire id for an engine profile (a page's `profileID`).
    func profile(of engine: BrowserProfileID) -> String {
        services.browserStores.offTheRecord.isOffTheRecord(engine) ? BrowserProfileRecord.defaultID : BrowserProfileRecord.wireID(for: engine)
    }

    func isBookmarked(_ url: URL?, profile: String) -> Bool { tree(profile).isBookmarked(url) }

    /// `profile`'s tree is the stored one, not an empty placeholder: the
    /// daemon's reply arrived (after an older build's file was copied over).
    func isLoaded(_ profile: String) -> Bool {
        usesDaemon && loadedFromDaemon.contains(profile)
    }

    /// The folder a new bookmark goes to: the last one used, else the bar.
    func defaultFolder(profile: String) -> String {
        if let folder = lastFolder[profile], tree(profile).isContainer(folder) { return folder }
        return BookmarkRoot.bar.rawValue
    }

    // MARK: Writing

    /// Applies `operation` to `profile`'s tree and sends it to the daemon.
    /// Validation errors throw before anything changes; so does an edit
    /// before the home daemon serves bookmarks (it has nowhere to go).
    @discardableResult
    func apply(_ operation: BookmarkOperation, profile: String) throws -> BookmarkChange {
        guard usesDaemon else { throw DaemonError.notConnected }
        var tree = tree(profile)
        let change = try tree.apply(operation)
        guard !change.isEmpty || isImport(operation) else { return change }
        trees[profile] = tree
        if case .create(let node, _) = operation { lastFolder[profile] = node.parent }
        send(operation, profile: profile)
        changed(profiles: [profile])
        return change
    }

    /// The home daemon's routed `bookmarks.*` ops (codec, imports, search, rank).
    var routed: BookmarkRoutedClient { BookmarkRoutedClient(connection: services.machines.local.connection) }

    /// Marks a bookmark as used now (opened from any bookmark surface).
    func touch(_ id: String, profile: String) {
        try? apply(.update(id: id, lastUsed: .set(Date())), profile: profile)
    }

    private func isImport(_ operation: BookmarkOperation) -> Bool {
        if case .importDrafts = operation { return true }
        return false
    }

    /// Every view of `profiles` redraws (stars, bars; the manager page follows the daemon's events).
    func changed(profiles: Set<String>) {
        generation &+= 1
        refreshChromes(profiles: profiles)
        chromium?.treesChanged(profiles)
    }

    /// A browser profile was deleted: its bookmarks go too (the daemon
    /// deletes its rows itself).
    func dropProfile(_ profile: String) {
        trees[profile] = nil
        fetched.remove(profile)
        loadedFromDaemon.remove(profile)
    }
}

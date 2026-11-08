import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Observation
import os

/// Bookmarks of every browser profile (plans/cmux-next/bookmarks.md): where they are, and the
/// fan-out to the omnibar stars, the bookmarks bars and Chromium.
///
/// The home daemon's `bookmarks-v1` table is the one copy of the tree. The app keeps none: every
/// read and edit is one of its routed `bookmarks.*` ops (``routed``), whose rules run in Rust
/// (cmux-bookmarks-core, cmux-bookmarks-ops). What a star or a bar must know in the same frame
/// (whether the page a tab shows is bookmarked, whether the bar has anything) is a small read-only
/// cache of `bookmarks.status` for the pages on screen (``statuses``), read again on the daemon's
/// `bookmarks-changed`. A `bookmarks.json` left by an older build is copied into the daemon once
/// (`bookmarks.import_legacy_file`) and then deleted.
@Observable @MainActor
final class BookmarkService {
    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored var directory: URL?
    @ObservationIgnored var importStore: ImportedDataStore?
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
    /// Chromium's bookmark models follow the daemon's trees (chrome.bookmarks bridge).
    @ObservationIgnored var chromium: BookmarkChromiumSync?
    @ObservationIgnored var showsBar = false
    /// Each profile's status for the pages its tabs show.
    @ObservationIgnored var statuses = BookmarkStatusCache()
    /// The one status read in flight per profile, and the profiles to read again after it.
    @ObservationIgnored var statusReads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var statusStale: Set<String> = []
    /// The omnibar suggestion engines, by profile, that index the profile's bookmarks.
    @ObservationIgnored var feeds: [String: [() -> OmniboxSuggestionEngine?]] = [:]
    /// The row a bar's context menu opened for: its menu's rows follow it (a folder's icon rows).
    @ObservationIgnored var menuTarget: MenuTarget?
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "bookmarks")

    final class WeakChrome {
        weak var entry: BrowserEntry?
        let bar: BookmarksBarHostView
        init(entry: BrowserEntry, bar: BookmarksBarHostView) {
            self.entry = entry
            self.bar = bar
        }
    }

    struct MenuTarget: Equatable {
        var id: String
        var profile: String
        var isFolder: Bool
        var icon: String?
    }

    /// An edit before the home daemon serves bookmarks: it has nowhere to go.
    struct Unavailable: Error {
        var message: String
    }

    /// The pages of the bookmarks bars on screen, lent to the tab whose bar is in a window.
    @ObservationIgnored lazy var barPages = BookmarksBarPages { [weak self] in self?.services.bookmarksBarPage() }

    init(services: AppServices) {
        self.services = services
    }

    /// Observes the home daemon, which runs the one-time migrations once it serves bookmarks
    /// (an older build's file, earlier browser imports).
    func start(directory: URL, importStore: ImportedDataStore?) {
        self.directory = directory
        self.importStore = importStore
        services.importedBookmarkSink = BookmarkImportSink(service: self)
        chromium = BookmarkChromiumSync(service: self)
        services.machines.local.store.sideEvents.subscribe { [weak self] event in
            if case .bookmarksChanged(let profile, _) = event { self?.daemonChanged(profile) }
        }
        observeHome()
    }

    /// The home daemon serves bookmarks; every read and write goes there.
    var usesDaemon: Bool { services.machines.local.supports(DaemonCapability.bookmarks.rawValue) }

    /// The home daemon's routed `bookmarks.*` ops.
    var routed: BookmarkRoutedClient { BookmarkRoutedClient(connection: services.machines.local.connection) }

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

    // MARK: Writing

    /// The daemon's ops in turn; a refusal throws with the rule that refused. Before the home
    /// daemon serves bookmarks it throws ``Unavailable`` with the capability gate's own text.
    @discardableResult
    func apply(_ ops: [BookmarkRoutedClient.Op]) async throws -> BookmarkRoutedClient.JSONValue {
        guard usesDaemon else { throw unavailable }
        return try await routed.apply(ops)
    }

    /// Why bookmarks cannot change now, in the home daemon's capability gate's own text.
    var unavailable: Unavailable {
        Unavailable(message: services.machines.local.missingCapabilityMessage(DaemonCapability.bookmarks.rawValue))
    }

    /// ``apply(_:)`` for an edit nothing waits on: a refusal is said in the refusal toast.
    func run(_ ops: [BookmarkRoutedClient.Op], quiet: Bool = false) {
        // task-owner: one routed edit; ends with its reply
        Task { [weak self] in
            do { try await self?.apply(ops) } catch {
                guard let self else { return }
                logger.error("bookmark edit refused: \(String(describing: error), privacy: .public)")
                if !quiet { services.registry.refuse(BookmarkAppStrings.failure(error)) }
            }
        }
    }

    /// Marks a bookmark as used now (opened from any bookmark surface). Quiet: nothing to act on.
    func touch(_ id: String, profile: String) {
        guard usesDaemon else { return }
        run([.update(id: id, lastUsed: Date())], quiet: true)
    }

    /// The home daemon changed `profile`'s tree: the stars, bars, omnibar index and Chromium read again.
    func daemonChanged(_ profile: String) {
        guard usesDaemon else { return }
        refreshStatus(profile)
        refreshFeeds(profile)
        chromium?.treesChanged([profile])
    }

    /// A browser profile was deleted: its bookmarks go too (the daemon deletes its rows itself).
    func dropProfile(_ profile: String) {
        statuses.drop(profile)
        statusReads[profile]?.cancel()
        statusReads[profile] = nil
        lastFolder[profile] = nil
    }
}

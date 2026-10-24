public import CmuxNextDesign
public import CmuxNextSettings
public import Foundation
import CmuxNextWakeups
import Observation

/// The wallpaper grid's choices, listed from disk once and again only when a folder they come
/// from changes (perf100 app lane).
///
/// The Settings page's host lists run inside Observation tracking and run again on every change
/// of any store they read. They listed the macOS wallpaper folders and the person's backgrounds
/// folder on each run: on a busy app that was most of that page's main-thread time, with an
/// `lstat` and a file read per wallpaper. Now the listing is cached and a folder event marks it
/// stale; ``revision`` is observable, so the page's host-lists watch sends the new list when a
/// folder changes. The folder events come from the injected `changes` (the App passes FSEvents);
/// no timer, no polling.
@Observable
public final class BackdropCatalogSource {
    /// A folder's changes: the names of the direct children that changed, or nil for "list it
    /// again" (a rescan). Ending the iteration stops the watch.
    public typealias FolderChanges = @MainActor (URL) -> AsyncStream<[String]?>

    /// Bumped by a change in a watched folder (and by ``refresh()``).
    public private(set) var revision = 0
    /// Listings from disk so far (debug.layout_counters `backdrop_catalog_builds`).
    @ObservationIgnored public private(set) var builds = 0
    @ObservationIgnored private var cached: (revision: Int, catalog: BackdropCatalog, rows: JSONValue)?
    @ObservationIgnored private var watched: [String: (filter: Filter, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private let settle = DemandTimer(owner: "BackdropCatalogSource.settle")
    @ObservationIgnored private let changes: FolderChanges
    @ObservationIgnored private let build: @MainActor () -> BackdropCatalog
    @ObservationIgnored private let folders: @MainActor () -> [URL]

    public init(changes: @escaping FolderChanges,
                build: @escaping @MainActor () -> BackdropCatalog = BackdropCatalogSource.listFromDisk,
                folders: @escaping @MainActor () -> [URL] = BackdropCatalogSource.sourceFolders) {
        self.changes = changes
        self.build = build
        self.folders = folders
    }

    /// The current catalog (an observed read of ``revision``).
    public var catalog: BackdropCatalog { current().catalog }

    /// The page rows of ``catalog`` (`BackdropCatalog.pageRows`), cached with it.
    public var pageRows: JSONValue { current().rows }

    /// Lists the folders again on the next read (an image the app itself just added).
    public func refresh() { revision &+= 1 }

    private func current() -> (revision: Int, catalog: BackdropCatalog, rows: JSONValue) {
        let revision = revision
        if let cached, cached.revision == revision { return cached }
        // Watch first: a change between the listing and the stream's start then marks the new
        // listing stale (one extra listing) instead of being lost.
        watch(folders())
        let catalog = build()
        builds += 1
        let entry = (revision, catalog, catalog.pageRows)
        cached = entry
        return entry
    }

    /// Keeps one folder watch per source folder. A folder that does not exist yet is watched
    /// through its nearest existing parent, which reacts only to the child on the way to it, so
    /// its creation marks the list stale and other changes there (a settings file) do not.
    private func watch(_ wanted: [URL]) {
        // Per watched folder: any change, or only changes to the named children.
        var targets: [String: Filter] = [:]
        for url in wanted {
            let (folder, child) = Self.nearestExisting(url)
            switch (targets[folder.path], child) {
            case (.any?, _), (_, nil): targets[folder.path] = .any
            case (.children(let names)?, let child?): targets[folder.path] = .children(names.union([child]))
            case (nil, let child?): targets[folder.path] = .children([child])
            }
        }
        for (path, entry) in watched where targets[path] != entry.filter {
            entry.task.cancel()
            watched[path] = nil
        }
        for (path, filter) in targets where watched[path] == nil {
            let stream = changes(URL(fileURLWithPath: path, isDirectory: true))
            // task-owner: one folder watch per source folder for the app's life; ends when the folder leaves the set
            let task = Task { @MainActor [weak self] in
                for await items in stream {
                    guard let self else { return }
                    if let items {
                        switch filter {
                        // A parent watched for one missing child: only that name counts (it may contain a dot).
                        case .children(let names): if names.isDisjoint(with: items) { continue }
                        case .any: if !items.contains(where: Self.listable) { continue }
                        }
                    }
                    // One listing per burst (a download writes its file many times).
                    self.settle.scheduleIfIdle(after: Self.burst) { @MainActor [weak self] in self?.revision &+= 1 }
                }
            }
            watched[path] = (filter, task)
        }
    }

    /// How long a burst of folder events is gathered into one new listing.
    static let burst: Duration = .milliseconds(500)

    /// A name the listing could show: a picture or movie, a macOS wallpaper download (`*.asset`),
    /// the aerials' `entries.json`, or a folder. Hidden and temporary files are not.
    nonisolated static func listable(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.hasSuffix("~") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty || ext == "asset" || name == "entries.json" || BackdropUserImages.extensions.contains(ext)
    }

    private enum Filter: Equatable {
        case any
        case children(Set<String>)
    }

    /// `url`, or its nearest existing parent and the name of the parent's child toward `url`.
    private static func nearestExisting(_ url: URL) -> (folder: URL, child: String?) {
        var folder = url.standardizedFileURL
        var child: String?
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" {
            child = folder.lastPathComponent
            folder = folder.deletingLastPathComponent()
        }
        return (folder, child)
    }

    /// The person's own background images, in the backgrounds folder.
    public static var userImages: BackdropUserImages? {
        BackdropArtDownloads.defaultFolder.map(BackdropUserImages.init(folder:))
    }

    /// The listing the picker shows.
    public static func listFromDisk() -> BackdropCatalog {
        BackdropCatalog(systemDirectory: AppleWallpapers.system.desktopPictures, fileManager: .default, userImages: userImages)
    }

    /// Every folder ``listFromDisk()`` reads: the macOS wallpapers, their downloads, the aerials
    /// (and their direct subfolders, where the movies are) and the person's backgrounds folder.
    /// Not watched: a download that macOS fills into an existing `*.asset/AssetData` (a new
    /// download adds a new `.asset` folder, which is), and the wallpapers' subfolders on the
    /// sealed system volume.
    public static func sourceFolders() -> [URL] {
        let aerials = AppleWallpapers.system.aerials
        let aerialFolders = (try? FileManager.default.contentsOfDirectory(
            at: aerials, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        return [AppleWallpapers.system.desktopPictures, aerials] + aerialFolders + AppleWallpaperAssets.systemFolders
            + [userImages?.folder].compactMap { $0 }
    }
}

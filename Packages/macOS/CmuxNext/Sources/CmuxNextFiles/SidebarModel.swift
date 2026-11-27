public import Foundation
import Observation

/// The Files sidebar: Favorites (defaults plus the person's own, in their
/// order, kept in `defaults`) and Locations (mounted volumes).
@MainActor
@Observable
public final class SidebarModel {
    /// The Favorites, top to bottom.
    public private(set) var favorites: [URL]
    /// The Locations, top to bottom.
    public private(set) var locations: [SidebarVolume]
    /// Whether the sidebar shows (Ctrl+Cmd+S).
    public var isVisible: Bool { didSet { defaults.set(isVisible, forKey: Self.visibleKey) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let volumes: @Sendable @concurrent () async -> [SidebarVolume]
    /// Numbers each read of the volumes in the order they start.
    @ObservationIgnored private var volumeRead: UInt64 = 0
    /// The newest read shown; a read that lands after a newer one was shown is dropped.
    @ObservationIgnored private var shownRead: UInt64 = 0
    /// The launch's first read (task-owner: the model; it ends once the volumes are read).
    @ObservationIgnored private var firstRead: Task<Void, Never>?
    private static let favoritesKey = "files.sidebar.favorites"
    private static let visibleKey = "files.sidebar.visible"

    /// Makes a sidebar.
    /// - Parameters:
    ///   - home: The person's home folder (for the default Favorites).
    ///   - defaults: Where the Favorites order is kept. Tests pass a suite of their own.
    ///   - volumes: Reads the mounted volumes, off the main thread (a slow network or disk image volume can
    ///     hold `mountedVolumeURLs` for seconds).
    ///
    /// Locations start empty and fill in once the first read lands; `await` ``refreshLocations()`` to wait for it.
    public init(home: URL, defaults: UserDefaults, volumes: @escaping @Sendable @concurrent () async -> [SidebarVolume]) {
        self.defaults = defaults
        self.volumes = volumes
        if let paths = defaults.stringArray(forKey: Self.favoritesKey) {
            favorites = paths.map { URL(filePath: $0, directoryHint: .notDirectory) }
        } else {
            favorites = [GoPlace.applications, .desktop, .documents, .downloads, .home].map { Self.normalized($0.url(home: home)) }
        }
        isVisible = defaults.object(forKey: Self.visibleKey) as? Bool ?? true
        locations = []
        firstRead = Task { [weak self] in await self?.refreshLocations() }
    }

    /// Makes a sidebar whose Locations are this Mac's mounted volumes (``SidebarVolume/read()``).
    /// An overload, not a closure default: an async closure literal as a default argument is banned
    /// (plans/cmux-next/crash-elimination.md, `async_closure_default_arg`).
    public convenience init(home: URL, defaults: UserDefaults) {
        self.init(home: home, defaults: defaults, volumes: SidebarVolume.read)
    }

    /// Adds `url` at `index` (dragging a folder in), or moves it there when it is already a Favorite.
    public func addFavorite(_ url: URL, at index: Int) {
        var list = favorites.filter { $0.path != url.path }
        list.insert(Self.normalized(url), at: max(0, min(index, list.count)))
        save(list)
    }

    /// Removes `url` from the Favorites (dragging it out, or Remove from Sidebar).
    public func removeFavorite(_ url: URL) {
        save(favorites.filter { $0.path != url.path })
    }

    /// Moves the Favorite at `from` to `to` (reordering by drag).
    public func moveFavorite(from: Int, to: Int) {
        guard favorites.indices.contains(from) else { return }
        var list = favorites
        let item = list.remove(at: from)
        list.insert(item, at: max(0, min(to, list.count)))
        save(list)
    }

    /// Reads the mounted volumes again (after a mount, unmount or rename), off the main thread, and
    /// shows them unless a read that started later was shown already.
    public func refreshLocations() async {
        volumeRead &+= 1
        let read = volumeRead
        let now = await volumes()
        guard read > shownRead else { return }
        shownRead = read
        if now != locations { locations = now }
    }

    /// One spelling per folder (no trailing slash), so saved and live Favorites compare equal.
    private static func normalized(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.path, directoryHint: .notDirectory)
    }

    private func save(_ list: [URL]) {
        favorites = list
        defaults.set(list.map(\.path), forKey: Self.favoritesKey)
    }
}

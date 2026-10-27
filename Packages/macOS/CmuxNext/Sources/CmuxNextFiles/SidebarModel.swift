public import Foundation
public import Observation

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
    @ObservationIgnored private let volumes: @MainActor () -> [SidebarVolume]
    private static let favoritesKey = "files.sidebar.favorites"
    private static let visibleKey = "files.sidebar.visible"

    /// Makes a sidebar.
    /// - Parameters:
    ///   - home: The person's home folder (for the default Favorites).
    ///   - defaults: Where the Favorites order is kept. Tests pass a suite of their own.
    ///   - volumes: Reads the mounted volumes. Defaults to ``SidebarVolume/mounted()``.
    public init(home: URL, defaults: UserDefaults,
                volumes: @escaping @MainActor () -> [SidebarVolume] = { SidebarVolume.mounted() }) {
        self.defaults = defaults
        self.volumes = volumes
        if let paths = defaults.stringArray(forKey: Self.favoritesKey) {
            favorites = paths.map { URL(filePath: $0, directoryHint: .notDirectory) }
        } else {
            favorites = [GoPlace.applications, .desktop, .documents, .downloads, .home].map { Self.normalized($0.url(home: home)) }
        }
        isVisible = defaults.object(forKey: Self.visibleKey) as? Bool ?? true
        locations = volumes()
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

    /// Reads the mounted volumes again (after a mount, unmount or rename).
    public func refreshLocations() {
        let now = volumes()
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

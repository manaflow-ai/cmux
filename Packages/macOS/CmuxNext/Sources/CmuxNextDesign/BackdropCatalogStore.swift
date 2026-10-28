public import Foundation
public import Observation
import CmuxNextWakeups

/// The wallpaper choices, kept current off the main thread (``BackdropCatalog``).
///
/// Building the catalog lists the Desktop Pictures folders, decodes `.madesktop` plists and sorts a
/// few hundred entries: tens of milliseconds, up to 216 ms in the every-action sweep (macOS 26,
/// appearance.customize). The Settings page rebuilt it on the main thread every time its host
/// lists were read, which is after any appearance change while the page is open. Here it is built
/// once off main and again only after a folder it lists changes (``FolderChanges``: a wallpaper
/// macOS downloaded, an image the person added); readers get the last one, observed.
///
/// ```swift
/// let store = BackdropCatalogStore(systemDirectory: AppleWallpapers.system.desktopPictures, userImages: images)
/// store.start()
/// let rows = store.catalog.choices
/// ```
@MainActor
@Observable
public final class BackdropCatalogStore {
    /// The latest catalog; the bundled art only until the first build lands.
    public private(set) var catalog: BackdropCatalog
    /// Builds completed (tests wait on it through observation).
    public private(set) var builds = 0

    @ObservationIgnored private let build: @Sendable () -> BackdropCatalog
    @ObservationIgnored private let folders: [URL]
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - systemDirectory: The macOS wallpaper folder.
    ///   - userImages: The person's own images and videos, if any.
    ///   - aerials: Where idleassetsd keeps downloaded aerials.
    ///   - assetFolders: Where macOS keeps downloaded full pictures.
    public init(systemDirectory: URL, userImages: BackdropUserImages?, aerials: URL = AppleWallpapers.system.aerials,
                assetFolders: [URL] = AppleWallpaperAssets.systemFolders) {
        catalog = BackdropCatalog(bundledOnly: ())
        build = {
            BackdropCatalog(systemDirectory: systemDirectory, fileManager: FileManager(),
                            assets: AppleWallpaperAssets(folders: assetFolders, fileManager: FileManager()),
                            userImages: userImages, aerials: aerials)
        }
        folders = [systemDirectory, systemDirectory.appendingPathComponent(".wallpapers"), aerials] + assetFolders
            + (userImages.map { [$0.folder] } ?? [])
    }

    // cx-t7hu: not an isolated deinit (its runtime hop traps when released inside an action's scope).
    nonisolated deinit {}

    /// Builds the catalog off main now and after every change to a folder it lists, until ``stop()``.
    public func start() {
        guard task == nil else { return }
        let build = build, folders = folders
        // task-owner: the store's refresh loop; stop() cancels it
        task = Task { [weak self] in
            var watched = Set(folders)
            // wakeup-allow: rearm only when a catalog changes the folders; otherwise await a file event.
            watch: while !Task.isCancelled {
                let changes = FolderChanges(folders: Array(watched)).events()
                await self?.refresh(build)
                guard let next = self?.watchFolders(folders) else { return }
                if next != watched { watched = next; continue }
                for await _ in changes {
                    guard let self else { return }
                    await self.refresh(build)
                    let next = self.watchFolders(folders)
                    if next != watched { watched = next; continue watch }
                }
                return
            }
        }
    }

    /// A download changes its movie's parent folder, not the aerial root (folder watches are not recursive).
    private func watchFolders(_ folders: [URL]) -> Set<URL> {
        Set(folders).union(catalog.choices.compactMap { choice in
            guard case .system(let path) = choice, choice.isVideo else { return nil }
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        })
    }

    /// Stops watching the folders.
    public func stop() {
        task?.cancel()
        task = nil
    }

    private func refresh(_ build: @escaping @Sendable () -> BackdropCatalog) async {
        let fresh = await Self.built(build)
        if fresh != catalog { catalog = fresh }
        builds += 1
    }

    @concurrent
    private static func built(_ build: @Sendable () -> BackdropCatalog) async -> BackdropCatalog { build() }
}

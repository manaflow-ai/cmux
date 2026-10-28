public import Foundation
public import Observation
public import CmuxNextWakeups
public import CmuxNextAppearance

/// The wallpaper choices, kept current off the main thread (``BackdropCatalog``).
///
/// Building the catalog lists the Desktop Pictures folders, decodes `.madesktop` plists and sorts a
/// few hundred entries: tens of milliseconds, up to 216 ms in the every-action sweep (macOS 26,
/// appearance.customize). The Settings page rebuilt it on the main thread every time its host
/// lists were read, which is after any appearance change while the page is open. Here it is built
/// once off main and again only after a folder it lists changes (``FolderChanges``: a wallpaper
/// macOS downloaded, an image the person added); readers get the last one, observed.
///
/// Each build runs on a nonisolated task and its result reaches main as one `visible` task on the
/// app's ``MainWorkScheduler`` (Chromium's `PostTaskAndReplyWithResult` onto a typed UI task runner,
/// base/task/task_runner_util.h, content/browser/scheduler/browser_task_queues.h): the Settings page
/// shows it, and no input of the person's caused it.
///
/// ```swift
/// let store = BackdropCatalogStore(systemDirectory: AppleWallpapers.system.desktopPictures, userImages: images,
///                                  mainWork: mainWork)
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
    @ObservationIgnored private let mainWork: MainWorkScheduler
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - systemDirectory: The macOS wallpaper folder.
    ///   - userImages: The person's own images and videos, if any.
    ///   - aerials: Where idleassetsd keeps downloaded aerials.
    ///   - assetFolders: Where macOS keeps downloaded full pictures.
    ///   - mainWork: The app's main-thread scheduler: each build lands as one `visible` task on it.
    public init(systemDirectory: URL, userImages: BackdropUserImages?, aerials: URL = AppleWallpapers.system.aerials,
                assetFolders: [URL] = AppleWallpaperAssets.systemFolders, mainWork: MainWorkScheduler) {
        catalog = BackdropCatalog(bundledOnly: ())
        self.mainWork = mainWork
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
        let build = build, folders = folders, mainWork = mainWork
        let owner = mainWork.board.owner("BackdropCatalogStore.build")
        // task-owner: the store's refresh loop, off main; stop() cancels it
        task = Task { @concurrent [weak self] in
            let changes = FolderChanges(folders: folders).events()
            let first = build()
            mainWork.postFromAnyThread(.visible, owner: owner) { [weak self] in self?.land(first) }
            // wakeup-allow: each pass is one folder change event, never a poll
            for await _ in changes {
                guard self != nil, !Task.isCancelled else { return }
                let fresh = build()
                mainWork.postFromAnyThread(.visible, owner: owner) { [weak self] in self?.land(fresh) }
            }
        }
    }

    /// Stops watching the folders.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// A build landed on main.
    private func land(_ fresh: BackdropCatalog) {
        if fresh != catalog { catalog = fresh }
        builds += 1
    }
}

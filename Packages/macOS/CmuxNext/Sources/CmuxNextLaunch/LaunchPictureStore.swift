import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// Deletes the saved launch pictures whose content must not stay on disk (p08-startup-100, section 3C): the browser
/// pages' (``BrowserLaunchPictures``) and the windows' (``WindowPictureStore``). Each quit replaces both sets, so
/// these deletions only bring that forward: a crash or a force quit after the change leaves nothing of it.
///
/// - Clear Browsing Data and a browser profile's delete: the pictures of that profile's pages saved in the range,
///   and every window picture that may show one (``WindowPictureMeta/mayShow(browserProfile:)``).
/// - A tab closed: its page picture and every window picture showing it. A window closed: its picture. A closed
///   tab or window never shows its picture again (the launch shows only what it restores, and the next quit's save
///   leaves it out), so every close is one for good here.
/// - `launch.savedPicture` off (``followSavedPicture(_:on:)``): every picture.
///
/// Chrome does the same with its tab captures: `PaintPreviewTabService::TabClosed` deletes a closed tab's capture and
/// `AuditArtifacts` the captures of tabs that no longer exist
/// (chrome/browser/paint_preview/services/paint_preview_tab_service.cc), and `BrowsingDataRemover` removes data in the
/// range the person picked (content/browser/browsing_data/browsing_data_remover_impl.cc).
///
/// Every deletion runs on one files-lane sequence in the order asked, never on the main thread; the main thread only
/// drops the matching pictures the launch read still holds in memory. The quit calls ``quitBegins()`` before its
/// saves: the deletions asked before have run by then, and the closes that follow (the quit ending sessions) delete
/// nothing the quit just saved.
///
/// ```swift
/// let deletions = LaunchPictureStore(pages: browserLaunchPictures, windows: windowPictures, work: work)
/// deletions.delete(.browserProfile(profile.rawValue, since: range.start(now: Date())))  // Clear Browsing Data
/// deletions.delete(.tab(key))                                                         // a tab closed
/// await deletions.quitBegins()                                                        // then the quit's saves
/// ```
@MainActor
public final class LaunchPictureStore {
    /// What to delete.
    public nonisolated enum Deletion: Sendable, Equatable {
        /// The pictures of browser profile `profile`'s pages saved at or after `since` (nil: any time), and the
        /// window pictures among them that may show one.
        case browserProfile(UUID, since: Date?)
        /// Tab `key`'s page picture and every window picture showing it.
        case tab(String)
        /// Window `id`'s picture.
        case window(String)
        /// Every saved picture.
        case all

        /// A close: dropped once the quit's saves begin.
        var isClose: Bool {
            switch self {
            case .tab, .window: true
            case .browserProfile, .all: false
            }
        }
    }

    /// The folders a deletion works in; nil: that kind of picture is not kept.
    public nonisolated struct Folders: Sendable, Equatable {
        public let pages: URL?
        public let windows: URL?

        public init(pages: URL?, windows: URL?) {
            (self.pages, self.windows) = (pages, windows)
        }
    }

    public let folders: Folders
    private weak var pages: BrowserLaunchPictures?
    private weak var windows: WindowPictureStore?
    private let deletions: WorkSequence
    private let remove: @Sendable (Deletion, Folders) -> Void
    /// The quit's saves began: closes delete nothing more.
    private var quitting = false

    /// - Parameters:
    ///   - pages: The browser pages' pictures; nil keeps none.
    ///   - windows: The windows' pictures; nil keeps none.
    ///   - work: The app's blocking-work lanes: the deletions run in order on its files lane.
    ///   - remove: Deletes on disk; default ``remove(_:in:)`` (tests record where it runs).
    public init(pages: BrowserLaunchPictures?, windows: WindowPictureStore?, work: BackgroundWork,
                remove: @escaping @Sendable (Deletion, Folders) -> Void = { LaunchPictureStore.remove($0, in: $1) }) {
        self.pages = pages
        self.windows = windows
        folders = Folders(pages: pages?.directory, windows: windows?.directory)
        deletions = work.sequence("launch-pictures.delete")
        self.remove = remove
    }

    /// Queues `deletion` on the files lane and returns at once. A clear, a profile delete and the setting off also
    /// drop the pictures the launch read holds, so none of them is shown after it.
    public func delete(_ deletion: Deletion) {
        if deletion.isClose, quitting { return }
        if !deletion.isClose {
            pages?.dropUnasked()
            windows?.dropFront()
        }
        guard folders.pages != nil || folders.windows != nil else { return }
        let folders = folders, remove = remove
        // A close's picture goes at the next quit anyway; what the person asked to delete must be gone before the exit.
        deletions.post(deletion.isClose ? .bestEffort : .userVisible, shutdown: deletion.isClose ? .skipOnShutdown : .blockShutdown) {
            remove(deletion, folders)
        }
    }

    /// Returns once every deletion queued before it has run.
    public func flush() async {
        _ = try? await deletions.run(.userVisible) {}
    }

    /// The quit's saves begin: returns once the deletions asked before have run, and closes asked from now delete
    /// nothing (the quit ends sessions after it saved their pictures). A clear or the setting off still deletes.
    public func quitBegins() async {
        quitting = true
        await flush()
    }

    /// Follows `launch.savedPicture`: each time it reads off, every saved picture is deleted (``Deletion/all``) at
    /// once, not at the next quit. A launch that loads it off deletes any the last run left.
    ///
    /// - Parameters:
    ///   - savedPicture: Reads the setting; nil until the settings first load (the person's choice is not known).
    ///   - mainWork: The app's main-thread scheduler.
    /// - Returns: The follower; the caller keeps it for as long as the setting is followed (the app's life).
    public func followSavedPicture(_ savedPicture: @escaping @MainActor () -> Bool?, on mainWork: MainWorkScheduler) -> ServiceObservation<Bool?> {
        // `background`: nothing on screen waits for the delete.
        ServiceObservation(.background, owner: "LaunchPictureStore.savedPicture", on: mainWork, read: savedPicture) { [weak self] on in
            if on == false { self?.delete(.all) }
        }
    }

    /// Deletes what `deletion` names under `folders`, on the calling thread (a files-lane thread).
    public nonisolated static func remove(_ deletion: Deletion, in folders: Folders) {
        switch deletion {
        case .all:
            for folder in [folders.pages, folders.windows].compactMap(\.self) { try? FileManager.checked.removeItem(at: folder) }
        case .browserProfile(let profile, let since):
            if let pages = folders.pages { removePages(of: profile, since: since, in: pages) }
            if let windows = folders.windows {
                removeWindows(in: windows) { meta, saved in meta.mayShow(browserProfile: profile) && since.map { saved >= $0 } ?? true }
            }
        case .tab(let key):
            if let pages = folders.pages { removePage(key, in: pages) }
            if let windows = folders.windows { removeWindows(in: windows) { meta, _ in meta.shows(tab: key) } }
        case .window(let id):
            if let windows = folders.windows { removeWindow(id, in: windows) }
        }
    }

    // MARK: Pages

    /// Removes profile `profile`'s page pictures saved at or after `since` (nil: its whole folder).
    nonisolated static func removePages(of profile: UUID, since: Date?, in directory: URL) {
        let folder = directory.appending(path: profile.uuidString, directoryHint: .isDirectory)
        guard let since else {
            try? FileManager.checked.removeItem(at: folder)
            return
        }
        rewriteIndex(in: folder) { entry in
            // A file that cannot be dated goes too: nothing shows it was saved before the range.
            savedDate(of: folder.appending(path: BrowserLaunchPictures.fileName(entry.key))).map { $0 < since } ?? false
        }
    }

    /// Removes tab `key`'s page picture from every profile folder that holds one.
    nonisolated static func removePage(_ key: String, in directory: URL) {
        guard BrowserLaunchPictures.isFileSafe(key) else { return }
        for folder in subfolders(of: directory) where FileManager.checked.fileExists(atPath: folder.appending(path: BrowserLaunchPictures.fileName(key)).path) {
            rewriteIndex(in: folder) { $0.key != key }
        }
    }

    /// Keeps the entries of `folder`'s index that `keeps` accepts and deletes the others' files; an index left empty,
    /// or one that does not read, takes the whole folder (no launch reads a folder without one).
    private nonisolated static func rewriteIndex(in folder: URL, keeping keeps: (BrowserLaunchPictures.IndexEntry) -> Bool) {
        let manager = FileManager.checked
        let indexURL = folder.appending(path: BrowserLaunchPictures.indexName)
        guard let data = try? Data(blockingContentsOf: indexURL),
              let entries = try? JSONDecoder().blockingDecode([BrowserLaunchPictures.IndexEntry].self, from: data) else {
            try? manager.removeItem(at: folder)
            return
        }
        let kept = entries.filter(keeps)
        guard kept.count < entries.count else { return }
        guard !kept.isEmpty, let index = try? JSONEncoder().encode(kept) else {
            try? manager.removeItem(at: folder)
            return
        }
        // The index first: a picture it no longer lists is never read, even if its file's delete fails.
        BrowserLaunchPictures.writePrivate(index, to: indexURL)
        let keptKeys = Set(kept.map(\.key))
        for entry in entries where !keptKeys.contains(entry.key) && BrowserLaunchPictures.isFileSafe(entry.key) {
            try? manager.removeItem(at: folder.appending(path: BrowserLaunchPictures.fileName(entry.key)))
        }
    }

    // MARK: Windows

    /// Removes the window pictures whose meta and save date `matches` accepts; a picture whose meta does not read
    /// goes too (no launch shows it).
    nonisolated static func removeWindows(in directory: URL, matching matches: (WindowPictureMeta, Date) -> Bool) {
        let manager = FileManager.checked
        for folder in subfolders(of: directory) {
            let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".\(WindowPictureStore.metaExtension)") {
                let window = String(name.dropLast(WindowPictureStore.metaExtension.count + 1))
                let metaURL = folder.appending(path: name)
                let picture = folder.appending(path: "\(window).\(WindowPictureStore.pictureExtension)")
                if let data = try? Data(blockingContentsOf: metaURL),
                   let meta = try? JSONDecoder().blockingDecode(WindowPictureMeta.self, from: data),
                   let saved = savedDate(of: picture), !matches(meta, saved) { continue }
                // The meta first: a picture without one is never shown.
                try? manager.removeItem(at: metaURL)
                try? manager.removeItem(at: picture)
            }
            removeIfEmpty(folder)
        }
        removeIfEmpty(directory)
    }

    /// Removes window `id`'s picture from every profile folder.
    nonisolated static func removeWindow(_ id: String, in directory: URL) {
        guard WindowPictureStore.isFileSafe(id) else { return }
        let manager = FileManager.checked
        for folder in subfolders(of: directory) {
            try? manager.removeItem(at: folder.appending(path: "\(id).\(WindowPictureStore.metaExtension)"))
            try? manager.removeItem(at: folder.appending(path: "\(id).\(WindowPictureStore.pictureExtension)"))
            removeIfEmpty(folder)
        }
        removeIfEmpty(directory)
    }

    // MARK: Files

    /// The folders in `directory` (one per profile); none when it does not exist.
    private nonisolated static func subfolders(of directory: URL) -> [URL] {
        let manager = FileManager.checked
        return ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).compactMap { name in
            var isDirectory: ObjCBool = false
            let url = directory.appending(path: name, directoryHint: .isDirectory)
            return manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
        }
    }

    /// When `url`'s file was last written; nil when it does not exist.
    private nonisolated static func savedDate(of url: URL) -> Date? {
        (try? FileManager.checked.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private nonisolated static func removeIfEmpty(_ folder: URL) {
        let manager = FileManager.checked
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path), names.isEmpty else { return }
        try? manager.removeItem(at: folder)
    }
}

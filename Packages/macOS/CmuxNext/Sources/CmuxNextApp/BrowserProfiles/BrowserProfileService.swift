import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDaemon
import Foundation
import Observation
import os

/// Browser profiles of this app install (plans/cmux-next/data-model.md 5):
/// the records, which profile a new tab gets, and each tab's engine store.
///
/// Records live in `<Application Support>/<bundle id>/BrowserProfiles/
/// profiles.json`: the home daemon's `profiles-v1` has no browser profile
/// table yet. Workspace and room defaults use the home daemon's personal
/// state when it serves `profiles-v1` and this file otherwise, so the pin
/// that brings `profiles-v1` takes over with no migration step.
@Observable @MainActor
final class BrowserProfileService {
    private(set) var book = BrowserProfileBook()
    /// False until the file was read (a launch reads it off the main thread).
    private(set) var isLoaded = false
    @ObservationIgnored unowned let services: AppServices
    /// Nil until `load` (tests and a service that never loaded write nothing).
    @ObservationIgnored private(set) var file: BrowserProfileBookFile?
    /// The onboarding import's saved data (nil: no import migration).
    @ObservationIgnored private(set) var importStore: ImportedDataStore?
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser-profiles")

    init(services: AppServices) {
        self.services = services
    }

    /// `<Application Support>/<bundle id>/BrowserProfiles`.
    static func defaultDirectory(bundleID: String?) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: bundleID ?? "com.cmuxterm.app.next")
            .appending(path: "BrowserProfiles", directoryHint: .isDirectory)
    }

    /// Reads the file, then removes the data of profiles deleted in an
    /// earlier run and moves pre-profile imports (in `importStore`) into
    /// their own profiles.
    func load(directory: URL, importStore: ImportedDataStore? = nil) {
        let file = BrowserProfileBookFile(url: directory.appending(path: "profiles.json"))
        self.file = file
        self.importStore = importStore
        // task-owner: one-shot launch read of a small JSON file
        Task { [weak self] in
            let loaded = await file.load()
            guard let self else { return }
            book = loaded
            isLoaded = true
            refreshPresentation()
            loadWaiters.forEach { $0.resume() }
            loadWaiters.removeAll()
            cleanUpDeletedProfiles()
            migrateImports()
        }
    }

    /// Waits until the file was read.
    func loaded() async {
        if isLoaded { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    // MARK: Records

    var ordered: [BrowserProfileRecord] { book.ordered }

    func record(_ id: String?) -> BrowserProfileRecord? { id.flatMap(book.record) }

    /// A tab record's profile id as the name users see.
    func displayName(_ id: String?) -> String {
        record(id ?? BrowserProfileRecord.defaultID)?.name ?? BrowserProfileStrings.defaultName
    }

    /// Applies one edit and saves the book. Saves run one at a time in
    /// order, off the main thread.
    @discardableResult
    func edit<T>(_ change: (inout BrowserProfileBook) throws -> T) throws -> T {
        var copy = book
        let result = try change(&copy)
        guard copy != book else { return result }
        book = copy
        save()
        refreshPresentation()
        return result
    }

    private func save() {
        guard let file else { return }
        let snapshot = book, previous = saving, logger = logger
        // task-owner: chained single-file saves; each waits for the previous
        saving = Task {
            await previous?.value
            do { try await file.save(snapshot) } catch {
                logger.error("save browser profiles: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits for pending saves (tests, termination).
    func flush() async { await saving?.value }

    // MARK: Engine stores

    /// The engine store of a tab: an incognito window's session, else the
    /// profile its record names (fixed at creation), else the default one.
    func engineProfile(forTab key: String) -> BrowserProfileID {
        if let windows = services.windows, let incognito = windows.browserProfile(forWorkspace: services.workspaceID(ofTab: key)) {
            return incognito
        }
        return book.engineProfile(for: services.cache.tabModel(key)?.snapshot.browserProfileID)
    }

    /// The wire id of a tab's profile (nil record = `default`).
    func profileID(ofTab tab: TabModel) -> String {
        tab.snapshot.browserProfileID ?? BrowserProfileRecord.defaultID
    }
}

import struct CmuxSafeConcurrency.OwnerReference
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLaunch
import CmuxNextWakeups
import Foundation
import Observation
import os
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
    @ObservationIgnored private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    var services: AppServices? { servicesReference.resolve() }
    /// Nil until `load` (tests and a service that never loaded write nothing).
    @ObservationIgnored private(set) var file: BrowserProfileBookFile?
    /// The onboarding import's saved data (nil: no import migration).
    @ObservationIgnored private(set) var importStore: ImportedDataStore?
    @ObservationIgnored private var saving: Task<Void, any Error>?
    /// The file's launch read, signaled once it applied: `loaded()` and every browser tab's page at launch
    /// wait for it (`TabContentCache.enginesAwait`).
    @ObservationIgnored let loadRead = LaunchReadEvent("BrowserProfiles.loaded")
    /// The home daemon's records follow (``observeHomeRecords()``); nil until the file was read.
    @ObservationIgnored var homeRecordsObservation: ServiceObservation<ObservationTrigger<Bool>>?
    /// The live pages' store follow (``followRecordProfiles()``); nil until the file was read.
    @ObservationIgnored var recordProfileObservation: ServiceObservation<[(String, BrowserProfileID, URL)]>?
    @ObservationIgnored var migratingRecords = false
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "browser-profiles")

    init(services: AppServices) {
        servicesReference = OwnerReference(services: services)
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
        guard let services else { return }
        let file = BrowserProfileBookFile(url: directory.appending(path: "profiles.json"))
        self.file = file
        self.importStore = importStore
        // Until the book applied, no engine makes a tab's page with a profile chosen from an empty book (a deleted
        // profile's tab would reopen its store, Chrome opens a profile's windows from its loaded callback).
        services.cache.enginesAwait = loadRead
        let mainWork = services.mainWork
        // task-owner: one-shot launch read of a small JSON file. R-hop: read on the file's actor, off main; the book
        // applies in one visible task (the launch's browser pages wait for it).
        services.work.task(.userVisible) { [weak self] in
            let loaded = await file.load()
            mainWork.postFromAnyThread(.visible, owner: "BrowserProfiles.loaded") { [weak self] in self?.didLoad(loaded) }
        }
    }

    /// The file's launch read landed with `loaded`.
    private func didLoad(_ loaded: BrowserProfileBook) {
        book = loaded
        isLoaded = true
        refreshPresentation()
        cleanUpDeletedProfiles()
        observeHomeRecords()
        followRecordProfiles()
        migrateImports()
        loadRead.signal()
    }

    /// Waits until the file was read.
    func loaded() async {
        if isLoaded { return }
        _ = try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in loadRead.post { done.resume(returning: ()) } }
    }

    // MARK: Records

    /// Profiles in order: the home daemon's once they moved there
    /// (`browser-profiles-v1`), else this Mac's file.
    var ordered: [BrowserProfileRecord] {
        guard usesDaemonRecords, let services else { return book.ordered }
        return services.machines.local.store.personal.browserProfiles.map(Self.record(from:))
    }

    func record(_ id: String?) -> BrowserProfileRecord? { id.flatMap { id in ordered.first { $0.id == id } } }

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
        guard let services else { return }
        guard let file else { return }
        let snapshot = book, previous = saving, logger = logger
        // task-owner: chained single-file saves; each waits for the previous. R-hop: off main on the file's actor;
        // quit waits for each (one small atomic write, as Chrome's ImportantFileWriter blocks shutdown).
        saving = services.work.task(.userVisible, shutdown: .blockShutdown) {
            _ = try? await previous?.value
            do { try await file.save(snapshot) } catch {
                logger.error("save browser profiles: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Waits for pending saves (tests, termination).
    func flush() async { _ = try? await saving?.value }

    // MARK: Engine stores

    /// The engine store of a tab: an incognito window's session, else the
    /// profile its record names (fixed at creation), else the default one.
    func engineProfile(forTab key: String) -> BrowserProfileID {
        guard let services else { return book.engineProfile(for: nil) }
        if case let windows = services.windows, let incognito = windows.browserProfile(forWorkspace: services.workspaceID(ofTab: key)) {
            return incognito
        }
        return book.engineProfile(for: services.cache.tabModel(key)?.browserProfileID)
    }

    /// The wire id of a tab's profile (nil record = `default`).
    func profileID(ofTab tab: TabModel) -> String {
        tab.browserProfileID ?? BrowserProfileRecord.defaultID
    }
}

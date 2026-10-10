import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextOnboarding
import os

/// Owns the tool window (Import from Browser, Computer Use setup), the
/// browser-data import offer, the default-app registry and the imported
/// data, and feeds imported history to the omnibar at launch. Nothing opens
/// at launch (Lawrence 2026-10-09: a launch goes straight to the main
/// window).
@MainActor
final class OnboardingService {
    unowned let services: AppServices
    let defaultApps: any DefaultAppRegistering
    let importStore: ImportedDataStore
    /// The one tool window (set up in `init`).
    private let presenter = OnboardingWindowPresenter()
    var controller: OnboardingWindowController? { presenter.controller }
    /// The browser-data import offer on the first browser tab of a launch.
    private(set) lazy var browserImportOffer = BrowserImportOfferService(services: services)
    /// Background-discovered local folders offered by new agent tabs.
    private(set) var projectFolders: [String] = []
    private var projectScanTask: Task<Void, Never>?

    /// Computer Use Setup: the helper's grants for the palette action, Settings and the tool window.
    private(set) lazy var computerUseSetup = ComputerUseSetup.app(services: services)

    init(services: AppServices) {
        self.services = services
        let environment = ProcessInfo.processInfo.environment
        // Test launches never change the Mac's real default browser.
        defaultApps = environment[RecordingDefaultApps.environmentKey] == "1" ? RecordingDefaultApps() : SystemDefaultApps()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        importStore = ImportedDataStore(directory: support.appending(path: services.environment.launch.bundleID ?? "com.cmuxterm.app.next")
            .appending(path: "BrowserImport", directoryHint: .isDirectory))
        // Keep Cmd-T off the file system hot path. The scan is bounded and runs
        // once in the background while the app is starting.
        projectScanTask = Task { [weak self] in
            let folders = await Task.detached {
                var scan = AgentProjectScan.live()
                scan.filesPerApp = 200
                let agent = scan.run().map(\.id)
                let classic: [ClassicSessionWorkspace]
                do {
                    classic = try ClassicSessionImporter().read()
                } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")
                        .error("classic session snapshot could not be read: \(String(describing: error), privacy: .public)")
                    classic = []
                }
                func classicDirectories(_ layout: ClassicSessionLayout) -> [String] {
                    switch layout {
                    case .pane(let pane): pane.tabs.compactMap(\.workingDirectory)
                    case .split(_, _, let first, let second): classicDirectories(first) + classicDirectories(second)
                    }
                }
                let classicFolders = classic.flatMap { workspace in
                    [workspace.workingDirectory] + classicDirectories(workspace.layout)
                }
                var seen = Set<String>()
                return (agent + classicFolders).compactMap { path in
                    let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
                    return seen.insert(normalized).inserted ? normalized : nil
                }
            }.value
            guard let self else { return }
            projectFolders = folders
        }
        presenter.makeModel = { [weak self] step in
            self.map { OnboardingModel(services: AppOnboardingServices(owner: $0), step: step) }
        }
    }

    var isShowing: Bool { controller != nil }

    /// Opens the tool window for `step` (or brings the open one forward).
    /// `importKinds` checks only those kinds on the import step and
    /// `importTarget` names the cmux browser profile they go into (the
    /// browser-data offer: into the tab's profile); without kinds the step
    /// makes one profile per source.
    func show(step: OnboardingModel.Step, importKinds: Set<ImportDataKind>? = nil, importTarget: String? = nil) {
        presenter.show(step: step) { model, reused in
            if let importKinds {
                model.importer.preset(kinds: importKinds, into: importTarget)
            } else if reused {
                model.importer.resetTarget()
            }
        }
    }

    /// Imported history and bookmarks go into each browser profile's
    /// omnibar history at launch (after `BrowserProfileService` moved
    /// pre-profile imports into their own profiles).
    static func seedHistory(profiles: [String], store: ImportedDataStore, cache: TabContentCache) {
        // task-owner: one-shot launch load of the import store
        Task {
            for id in profiles {
                guard let profile = BrowserProfileRecord.engineProfile(for: id) else { continue }
                let batches = await store.batches(profile: id)
                if !batches.isEmpty { cache.history(for: profile).merge(batches.flatMap(Self.historyEntries)) }
            }
        }
    }

    /// A batch's pages as omnibar history. Bookmarks reach the omnibar as
    /// bookmark rows (`BookmarkSuggestionFeed`), not as visits.
    nonisolated static func historyEntries(_ batch: ImportBatch) -> [BrowserHistoryEntry] {
        batch.history.map { BrowserHistoryEntry(url: $0.url, title: $0.title, visitCount: $0.visitCount, lastVisit: $0.lastVisit) }
    }
}

/// Saves each imported profile and adds it to the live omnibar history.
struct AppImportDestination: ImportDestination {
    let store: ImportedDataStore
    /// The bookmarks model (`AppServices.importedBookmarkSink`), when present.
    var bookmarks: (any ImportedBookmarkSink)?
    /// The omnibar history of a browser profile id.
    let history: @MainActor @Sendable (String) -> InMemoryBrowserHistory

    func commit(_ batch: ImportBatch) async throws {
        try await store.save(batch)
        if let bookmarks, batch.kinds.contains(.bookmarks) {
            try await bookmarks.replaceImportedBookmarks(batch.bookmarks, source: batch.source)
        }
        let entries = OnboardingService.historyEntries(batch)
        let target = batch.source.targetProfileID
        await MainActor.run { history(target).merge(entries) }
    }
}

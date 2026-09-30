import AppKit
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextOnboarding
import os

/// Owns the onboarding window: shows it on the first launch (once per Mac
/// account, `OnboardingStateFile`), reopens it from the palette, the menu
/// and the import and default-app actions, and feeds imported history to
/// the omnibar at launch.
@MainActor
final class OnboardingService {
    unowned let services: AppServices
    let state: OnboardingStateFile
    let defaultApps: any DefaultAppRegistering
    let importStore: ImportedDataStore
    private(set) var controller: OnboardingWindowController?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")

    /// Shows onboarding on the first launch even in a no-activate test launch.
    static let forceKey = "CMUX_NEXT_ONBOARDING"

    init(services: AppServices) {
        self.services = services
        let environment = ProcessInfo.processInfo.environment
        state = OnboardingStateFile.live(environment: environment)
        // Test launches never change the Mac's real default browser.
        defaultApps = environment[RecordingDefaultApps.environmentKey] == "1" ? RecordingDefaultApps() : SystemDefaultApps()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        importStore = ImportedDataStore(directory: support.appending(path: services.environment.launch.bundleID ?? "com.cmuxterm.app.next")
            .appending(path: "BrowserImport", directoryHint: .isDirectory))
    }

    var isShowing: Bool { controller != nil }

    /// Opens onboarding at `step` (or brings the open one to that step).
    func show(step: OnboardingModel.Step = .welcome) {
        if let controller {
            controller.model.go(to: step)
            controller.present()
            return
        }
        let model = OnboardingModel(services: AppOnboardingServices(owner: self), start: step)
        let controller = OnboardingWindowController(model: model)
        controller.onClose = { [weak self] in self?.controller = nil }
        self.controller = controller
        controller.present()
    }

    /// First launch: show once the first window is up. A no-activate launch
    /// (agents, tests) skips it unless `CMUX_NEXT_ONBOARDING=1`.
    func showIfNeeded() {
        let forced = ProcessInfo.processInfo.environment[Self.forceKey] == "1"
        guard forced || !services.environment.noActivate else { return }
        let state = state
        // task-owner: one-shot launch check; ends after one file read
        Task { [weak self] in
            let needed = await Task.detached { state.needsOnboarding() }.value
            guard needed, let self, !self.isShowing else { return }
            show()
        }
    }

    func markDone(completed: Bool) {
        let state = state
        let logger = logger
        // task-owner: one small file write, off the main thread
        Task.detached {
            do { try state.markDone(completed: completed) } catch { logger.error("onboarding state: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Imported history and bookmarks go into the omnibar's history at launch.
    func seedHistory() {
        let store = importStore
        let history = services.cache.history
        // task-owner: one-shot launch load of the import store
        Task {
            let batches = await store.batches(profile: "default")
            history.merge(batches.flatMap(Self.historyEntries))
        }
    }

    /// A batch as omnibar history: pages as visited, bookmarks as one visit
    /// on the day they were added (cmux-next has no bookmark list yet).
    nonisolated static func historyEntries(_ batch: ImportBatch) -> [BrowserHistoryEntry] {
        batch.history.map { BrowserHistoryEntry(url: $0.url, title: $0.title, visitCount: $0.visitCount, lastVisit: $0.lastVisit) }
            + batch.bookmarks.map { BrowserHistoryEntry(url: $0.url, title: $0.title, visitCount: 1, lastVisit: $0.dateAdded ?? batch.importedAt) }
    }
}

/// Saves each imported profile and adds it to the live omnibar history.
struct AppImportDestination: ImportDestination {
    let store: ImportedDataStore
    let history: InMemoryBrowserHistory

    func commit(_ batch: ImportBatch) async throws {
        try await store.save(batch)
        let entries = OnboardingService.historyEntries(batch)
        await MainActor.run { history.merge(entries) }
    }
}

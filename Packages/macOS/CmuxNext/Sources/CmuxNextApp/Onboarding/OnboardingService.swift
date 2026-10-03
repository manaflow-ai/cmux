import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
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
    /// The role step's saved answer, read off the main thread at launch;
    /// "Onboarding…" opens the step with it.
    private(set) var profile: OnboardingProfile?
    /// Background-discovered local folders offered by new agent tabs.
    private(set) var projectFolders: [String] = []
    private var projectScanTask: Task<Void, Never>?
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
        let state = state
        // task-owner: one-shot launch read of the onboarding state file
        Task { [weak self] in
            let saved = await Task.detached { state.profile() }.value
            guard let self, profile == nil else { return }
            profile = saved
        }
        // Keep Cmd-T off the file system hot path. The scan is bounded and runs
        // once in the background while the app is starting.
        projectScanTask = Task { [weak self] in
            let folders = await Task.detached {
                var scan = AgentProjectScan.live()
                scan.filesPerApp = 200
                let agent = scan.run().map(\.id)
                func classicDirectories(_ layout: ClassicSessionLayout) -> [String] {
                    switch layout {
                    case .pane(let pane): pane.tabs.compactMap(\.workingDirectory)
                    case .split(_, _, let first, let second): classicDirectories(first) + classicDirectories(second)
                    }
                }
                let classic = (try? ClassicSessionImporter().read())?.flatMap { workspace in
                    [workspace.workingDirectory] + classicDirectories(workspace.layout)
                } ?? []
                var seen = Set<String>()
                return (agent + classic).compactMap { path in
                    let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
                    return seen.insert(normalized).inserted ? normalized : nil
                }
            }.value
            guard let self else { return }
            projectFolders = folders
        }
    }

    /// Keeps the role step's answer (a small file write, off the main thread).
    func saveProfile(_ answer: OnboardingProfile) {
        profile = answer
        let state = state
        write("onboarding profile") { try state.saveProfile(answer) }
    }

    /// The last state file write; each write waits for it, so a profile
    /// save can't land after `markDone` and undo it.
    private var lastWrite: Task<Void, Never>?

    /// Runs one small state file write off the main thread, after the one before.
    private func write(_ label: String, _ work: @escaping @Sendable () throws -> Void) {
        let previous = lastWrite
        let logger = logger
        // task-owner: one small file write, chained after the previous one
        lastWrite = Task.detached {
            await previous?.value
            do { try work() } catch { logger.error("\(label, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
    }

    /// The first task's chat, kept while the window is open so the step
    /// shows the same chat when the user comes back to it.
    private var firstTask: (cwd: URL, prompt: String, view: AgentPaneView)?

    func firstTaskView(cwd: URL, prompt: String) -> AgentPaneView? {
        if let firstTask, firstTask.cwd == cwd, firstTask.prompt == prompt { return firstTask.view }
        firstTask?.view.close()
        let view = services.agentTabs.standaloneView(seed: AgentPaneSeed(cwd: cwd.path, prompt: prompt))
        firstTask = view.map { (cwd, prompt, $0) }
        return view
    }

    var isShowing: Bool { controller != nil }
    private(set) var gallery: OnboardingGalleryController?
    /// The review tool's state: picks, notes, position
    /// (`~/Library/Application Support/cmux/<tag>/onboarding-feedback.json`).
    private(set) lazy var galleryStore = GalleryReviewStore(url: Self.galleryFile(tag: services.environment.tag))

    static func galleryFile(tag: String?) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "cmux").appending(path: tag ?? "default").appending(path: "onboarding-feedback.json")
    }

    /// The onboarding review tool (DEBUG builds): one window, every screen's variants.
    func showGallery() {
        if let gallery { return gallery.present() }
        let picks = AppOnboardingServices(owner: self)
        // task-owner: one-shot theme file load for the samples
        Task { [weak self] in
            let themes = await picks.loadThemeChoices()
            let ownTheme = await Task.detached { GhosttyOwnTheme.isSet() }.value
            guard let self, gallery == nil else { return }
            let accounts: () -> NSView? = { [weak self] in self.map { AppOnboardingServices(owner: $0).makeAccountsStepView() } ?? nil }
            let gallery = OnboardingGalleryController(store: galleryStore, makeServices: { store in
                let sample = MockOnboardingServices.gallerySample(themes: themes, accountsView: accounts())
                sample.ghosttyTheme = ThemeStore.shared.input
                sample.ghosttyHasOwnTheme = ownTheme
                for step in OnboardingModel.Step.allCases { sample.variantIDs[step] = store.pick(for: step) }
                return sample
            }, previewAppearance: { [weak self] dark in self?.services.terminalTheme.preview(dark: dark) })
            gallery.onClose = { [weak self] in self?.gallery = nil }
            self.gallery = gallery
            gallery.present()
        }
    }

    /// Opens onboarding at `step` (or brings the open one to that step).
    func show(step: OnboardingModel.Step? = nil) {
        if let controller {
            if let step { controller.model.go(to: step) }
            controller.present()
            return
        }
        let model = OnboardingModel(services: AppOnboardingServices(owner: self), start: step)
        let controller = OnboardingWindowController(model: model)
        controller.onClose = { [weak self] in
            self?.controller = nil
            // The task's session stays in acpmux (the agent may still be working); only the page closes.
            self?.firstTask?.view.close()
            self?.firstTask = nil
        }
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
        let profile = profile
        write("onboarding state") { try state.markDone(completed: completed, profile: profile) }
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
    /// bookmark rows (`BookmarkSuggestionProvider`), not as visits.
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

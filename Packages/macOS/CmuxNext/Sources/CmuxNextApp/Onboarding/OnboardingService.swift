import AppKit
import CmuxNextAgentActivity
import CmuxNextActions
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
    /// The state file's one writer (`OnboardingStateFile` per channel).
    let state: OnboardingStateQueue
    let defaultApps: any DefaultAppRegistering
    let importStore: ImportedDataStore
    /// The one onboarding window (set up in `init`).
    private let presenter = OnboardingWindowPresenter()
    var controller: OnboardingWindowController? { presenter.controller }
    /// Background-discovered local folders offered by new agent tabs.
    private(set) var projectFolders: [String] = []
    private var projectScanTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")

    /// Shows onboarding on the first launch even in a no-activate test launch.
    static let forceKey = "CMUX_NEXT_ONBOARDING"

    /// The cmux-cua socket the computer use step reads: the helper this app
    /// runs (`ComputerUseHelperDaemon`), else CMUX_NEXT_CUA_SOCKET or
    /// cmux-cua's default. Tests point it at their own socket.
    var computerUseConfiguration: AgentActivitySocketSource.Configuration {
        get { computerUseConfigurationOverride ?? ComputerUseHelperDaemon.shared.configuration ?? .standard(machineName: "") }
        set { computerUseConfigurationOverride = newValue }
    }
    private var computerUseConfigurationOverride: AgentActivitySocketSource.Configuration?

    /// Whether an open window can show `step` (`OnboardingWindowPresenter`).
    static func reusesWindow(showing steps: [OnboardingModel.Step], for step: OnboardingModel.Step?) -> Bool {
        OnboardingWindowPresenter.reusesWindow(showing: steps, for: step)
    }

    init(services: AppServices) {
        self.services = services
        let environment = ProcessInfo.processInfo.environment
        state = OnboardingStateQueue(file: OnboardingStateFile.live(environment: environment, bundleID: services.environment.launch.bundleID))
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
        presenter.makeModel = { [weak self] start, resume in
            self.map { OnboardingModel(services: AppOnboardingServices(owner: $0), start: start, resumingFirstRunAt: resume) }
        }
        presenter.onWindowClose = { [weak self] in
            // The task's session stays in acpmux (the agent may still be working); only the page closes.
            self?.firstTask?.view.close()
            self?.firstTask = nil
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
        presenter.show(step: step)
    }

    /// The first run is at `step`: kept so a relaunch (or Continue Setup)
    /// resumes it there. A finished run stays finished.
    func recordProgress(_ step: OnboardingModel.Step, interacted: Bool) {
        state.write("onboarding progress") { try $0.markProgress(step, interacted: interacted) }
    }

    /// Continue Setup (Help menu, palette, Settings): the open first run as
    /// it is, else the first run at its saved step (from its start when
    /// none is saved). Finished or not, it stays as it was.
    func continueSetup() {
        // task-owner: one queued file read, then the window opens
        Task { [weak self] in
            guard let state = self?.state else { return }
            let resume = await state.perform { $0.resumeStep() }
            self?.presenter.showFirstRun(resumingAt: resume)
        }
    }

    /// First launch: show once the first window is up. A no-activate launch
    /// (agents, tests) skips it unless `CMUX_NEXT_ONBOARDING=1`.
    func showIfNeeded() {
        let forced = ProcessInfo.processInfo.environment[Self.forceKey] == "1"
        guard forced || !services.environment.noActivate else { return }
        // task-owner: one-shot launch check; ends after one queued file read
        Task { [weak self] in
            guard let state = self?.state else { return }
            let decision = await state.perform { $0.takeLaunchShow() }
            guard let self, !isShowing else { return }
            switch decision {
            case .start: presenter.showFirstRun(resumingAt: nil)
            // An unfinished first run with launches left (each launch that
            // showed it counts, closed or quit) resumes at its step.
            case .resume(let step): presenter.showFirstRun(resumingAt: step)
            case .none: break
            }
        }
    }

    func markDone(completed: Bool) {
        state.write("onboarding state") { try $0.markDone(completed: completed) }
    }

    /// Onboarding ended: records it, and Done over Home lands on the New
    /// Tab page through the sidebar's New (`newTab`).
    func didEnd(completed: Bool) {
        // Only the first run's Skip or Done ends the first run; another
        // window's (Import and Sync, a single step) leaves it as it is.
        if controller?.model.isFirstRun ?? true { markDone(completed: completed) }
        guard Self.opensNewTab(completed: completed, shown: services.windows?.active?.shownTopPage) else { return }
        services.registry.perform("newTab")
    }

    /// Done (not Skip) opens the New Tab page when the window behind
    /// onboarding shows Home; reopened over a workspace or another page,
    /// the window stays as it is.
    nonisolated static func opensNewTab(completed: Bool, shown: TopPageRoute?) -> Bool {
        completed && shown == .home
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

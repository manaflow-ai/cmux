import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextOnboarding
import os

/// Owns onboarding: decides the first run once per launch (`FirstRunGate`),
/// opens the onboarding window from the palette, the menu and the import and
/// default-app actions (never at launch: the first run is the New Tab page),
/// and feeds imported history to the omnibar at launch.
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
    /// The cookie import card on browser pages (cx-367y).
    private(set) lazy var cookiePrompt = CookieImportPromptService(services: services)
    /// Background-discovered local folders offered by new agent tabs.
    private(set) var projectFolders: [String] = []
    private var projectScanTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")

    /// Turns on the cookie import card even in a no-activate test launch.
    static let forceKey = "CMUX_NEXT_ONBOARDING"

    /// Computer Use Setup: the helper's grants for the palette action, Settings and this step.
    private(set) lazy var computerUseSetup = ComputerUseSetup.app(services: services)

    /// Whether an open window can show `step` (`OnboardingWindowPresenter`).
    static func reusesWindow(showing steps: [OnboardingModel.Step], for step: OnboardingModel.Step?) -> Bool {
        OnboardingWindowPresenter.reusesWindow(showing: steps, for: step)
    }

    /// `stateFile` replaces the channel's state file (tests).
    init(services: AppServices, stateFile: OnboardingStateFile? = nil) {
        self.services = services
        let environment = ProcessInfo.processInfo.environment
        state = OnboardingStateQueue(file: stateFile ?? OnboardingStateFile.live(environment: environment, bundleID: services.environment.launch.bundleID))
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
    /// `importKinds` checks only those kinds on the import step and
    /// `importTarget` names the cmux browser profile they go into (the cookie
    /// import card: cookies, into the tab's profile); without kinds the step
    /// makes one profile per source.
    func show(step: OnboardingModel.Step? = nil, importKinds: Set<ImportDataKind>? = nil, importTarget: String? = nil) {
        presenter.show(step: step) { model, reused in
            if let importKinds {
                model.importer.preset(kinds: importKinds, into: importTarget)
            } else if reused {
                model.importer.resetTarget()
            }
        }
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

    /// cmux-next.json before this launch seeded it, read by the app delegate
    /// before seeding (`FirstRunGate.ConfigOrigin.beforeSeeding`).
    var configOrigin: FirstRunGate.ConfigOrigin = .absent
    /// This launch's first-run decision; nil until the daemon snapshot.
    private(set) var firstRunDecision: FirstRunGate.Decision?
    private var firstRunGate: Task<Void, Never>?

    /// The launch's first-run gate, once, after the daemon snapshot
    /// (`WindowManager.restore`). Reads acpmux history and classic's
    /// snapshot, then decides on the state queue. Nothing opens: a fresh
    /// user's first run is the launch's New Tab page, and a user with data
    /// ends onboarding silently (`reason: existing-data`).
    func evaluateFirstRun(firstWorkspaceNeeded: Bool) {
        guard firstRunGate == nil else { return }
        let config = configOrigin
        // task-owner: one-shot launch gate; one journal read, one stat, one queued file write
        firstRunGate = Task { [weak self] in
            guard let history = self?.services.history.agents else { return }
            await history.refresh()
            let sessions = history.sessions.count
            let classic = await Task.detached { ClassicSessionImporter().hasSnapshot }.value
            _ = await self?.decideFirstRun(FirstRunGate(firstWorkspaceNeeded: firstWorkspaceNeeded, agentSessions: sessions,
                                                        config: config, classicSnapshot: classic))
        }
    }

    /// Decides the first run in one queued operation: on existing data the
    /// same operation marks onboarding done with its reason.
    func decideFirstRun(_ gate: FirstRunGate) async -> FirstRunGate.Decision {
        let decision = await state.perform { $0.decideFirstRun(gate) }
        firstRunDecision = decision
        logger.info("first run: \(String(describing: decision), privacy: .public)")
        return decision
    }

    func markDone(completed: Bool) {
        state.write("onboarding state") { try $0.markDone(completed: completed) }
    }

    /// The workspace this launch created on the New Tab page because the
    /// tree had none (`FirstWorkspace`): the first run lands on it instead
    /// of opening a second one. Cleared once onboarding landed.
    var freshWorkspaceID: String?

    /// Onboarding ended (Skip or Done): records it, then lands (D3).
    func didEnd(completed: Bool) {
        // Only the first run's Skip or Done ends the first run; another
        // window's (Import and Sync, a single step) leaves it as it is.
        let firstRun = controller?.model.isFirstRun ?? true
        if firstRun { markDone(completed: completed) }
        land(firstRun: firstRun)
    }

    /// D3 (cx-aha.2): Skip and Done of the first run (also when Continue
    /// Setup reopened it) land on a New Tab page, one path for both
    /// buttons (`OnboardingLanding`). Selecting a workspace only changes
    /// what the window shows: no window is ordered front, so the person
    /// stays on their Space and a fullscreen window keeps its Space; with
    /// no window open, a new one opens on the current Space.
    private func land(firstRun: Bool) {
        let windows = services.windows
        let fresh = freshWorkspaceID.flatMap { services.machines.workspace(id: $0) == nil ? nil : $0 }
        let landing = OnboardingLanding.decide(firstRun: firstRun, hasOpenWindow: !windows.registry.value.openWindows.isEmpty,
                                               shown: windows.active?.shownTopPage, fresh: fresh)
        switch landing {
        case .stay: return
        case .select(let id): _ = windows.reveal(workspaceID: id)
        case .newWorkspace: services.registry.perform("newTab")
        }
        freshWorkspaceID = nil
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

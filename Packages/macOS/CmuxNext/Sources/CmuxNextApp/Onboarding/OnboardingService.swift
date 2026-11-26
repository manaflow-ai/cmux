import AppKit
import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAgentIntegrations
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextCookieImport
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextImportCards
import CmuxNextOnboarding
import CmuxNextSettings
import os

/// Owns the tool window (Import from Browser, Computer Use setup), the
/// browser-data import offer, the default-app registry and the imported
/// data, and feeds imported history to the omnibar at launch. First-run onboarding
/// (windows, Set Up cmux card, history page) is off unless `--onboarding`
/// (``AppEnvironment/launchSteps``): launches go straight to the main window. The one-time classic migration adds classic's workspaces
/// to the restored windows (classic-migration-DESIGN.md).
@MainActor
final class OnboardingService {
    unowned let services: AppServices
    let defaultApps: any DefaultAppRegistering
    let importStore: ImportedDataStore
    /// The one tool window (set up in `init`).
    private let presenter: OnboardingWindowPresenter
    var controller: OnboardingWindowController? { presenter.controller }
    /// The browser-data import offer on the first browser tab of a launch.
    private(set) lazy var browserImportOffer = BrowserImportOfferService(services: services)
    /// Background-discovered local folders offered by new agent tabs.
    private(set) var projectFolders: [String] = []
    private var projectScanTask: Task<Void, Never>?
    /// Follows `browser.import.enabled` (``BrowserImportGate``).
    private var importSettingFollow: Task<Void, Never>?
    private var cookieBannerFollow: Task<Void, Never>?

    /// How `workspace.importClassic` reaches a classic SSH workspace's host:
    /// the daemon for that destination. Nil connects through `SSHService`
    /// (tests stand in a daemon).
    var classicSSH: (@MainActor (String) throws -> DaemonService)?
    /// What acpmux would do with a classic agent session (`_acpmux/chat_open`):
    /// only `adopt` opens a chat. Nil asks this Mac's acpmux (tests answer).
    var classicChatPlan: (@MainActor (AgentPaneAdopt, String?) async throws -> AcpmuxChatOpenPlan?)?
    /// The toast `workspace.importClassic` or the launch migration showed last.
    var classicImportNotice: String?
    /// Whether launch runs the classic migration; nil decides by build (shipping builds only).
    var classicMigrationAtLaunch: Bool?
    /// Answers the migration preview; nil presents the native cmux dialog.
    /// Tests inject an answer without creating UI.
    var classicMigrationConfirmation: (@MainActor (ClassicImportPreview) async -> ClassicImportAnswer)?
    /// The app installs the import of its settings and palette history alongside the settings controller.
    var importClassicSettings: (@MainActor () async throws -> Void)?
    /// The migration run in flight or last finished: a new run waits for it.
    var classicMigrationRun: Task<ClassicMigrationOutcome, any Error>?

    /// Keep in Sync's watches (imported cookies' too); `start` also seeds each profile's omnibar with its imported pages.
    private(set) lazy var historySync = BrowserFolderAccess().historySync(store: importStore, reader: services.browserDataReader, cookies: ChromiumCookieDestination { [cef = services.cache.cef] in try await cef.importCookies($0, into: $1) },
        stopped: { [weak services] name in if let services { BrowserFileImport.toast(services, id: "cookie-sync-stopped", BrowserImportOfferStrings.syncStopped(name)) } },
        deliver: SavingImportDestination.omnibar(services.cache))

    /// Computer Use Setup: the helper's grants for the palette action, Settings and the tool window.
    private(set) lazy var computerUseSetup = ComputerUseSetup.app(services: services)

    /// The Agents step's sign-ins: Settings > Agents > Harnesses' reader over this Mac's acpmux.
    private(set) lazy var signInHarnesses = SettingsHarnesses(environment: { [weak services] in services.flatMap(QuitAgents.environment) },
        openTerminal: { [weak self] line in await self?.openSignIn(line) ?? false }, openSignInPage: { [weak services] url in services?.linkOpener.openSignInPage(url, beside: nil) })
    /// Settings > Agents' cmux Tools card: `agents.cmuxMcp` and `cmux setup mcp`'s report.
    private(set) lazy var agentTools = AgentToolsCLISource(cli: { [bundled = services.bundledCLI] in await bundled.resolve() }, settings: { [weak services] in services?.settings })
    /// Make cmux Yours' choices over the settings owner (each pick one publish; the reload applies density's tokens); unset Opacity reads the window's.
    private(set) lazy var firstRunChoices = FirstRunChoicesSettingsSource(settings: { [weak services] in services?.settings },
        windowOpacity: { [weak services] in (services?.windows.active?.themeScope ?? ThemeScope.app).shownWindowOpacity })
    /// The top page a Sign In left; it shows again once the tool window closes.
    private var pageLeftForSignIn: TopPageRoute?

    init(services: AppServices) {
        self.services = services
        presenter = OnboardingWindowPresenter(activeLook: services.activeLook)
        let environment = ProcessInfo.processInfo.environment
        // Test launches never change the Mac's real default browser.
        defaultApps = environment[RecordingDefaultApps.environmentKey] == "1" ? RecordingDefaultApps() : SystemDefaultApps()
        let support = NextSupport.applicationSupportDirectory()
        importStore = ImportedDataStore(directory: support.appending(path: services.environment.launch.bundleID ?? "com.cmuxterm.app.next")
            .appending(path: "BrowserImport", directoryHint: .isDirectory))
        // Keep Cmd-T off the file system hot path. The scan is bounded and runs
        // once in the background while the app is starting.
        projectScanTask = Task { [weak self] in
            let agent = await Task.detached {
                var scan = AgentProjectScan.live()
                scan.filesPerApp = 200
                return scan.run().map(\.id)
            }.value
            guard let self else { return }
            addProjectFolders(agent + (classicFolderDefaults?.stringArray(forKey: Self.classicFoldersKey) ?? []))
        }
        presenter.makeModel = { [weak self] step in
            self.map { OnboardingModel(services: AppOnboardingServices(owner: $0), step: step, choices: $0.firstRunChoices) }
        }
        presenter.onWindowClose = { [weak self] in
            guard let self, let page = pageLeftForSignIn else { return }
            pageLeftForSignIn = nil
            _ = TopPages.show(page, services: services)
        }
    }

    var classicFolderDefaults: UserDefaults?
    private static let classicFoldersKey = "classicImportedProjectFolders"

    /// Remember local project suggestions from the accepted plan in NEXT's defaults.
    func rememberClassicFolders(in plan: ClassicMigrationPlan) {
        let folders = plan.workspaces.filter { $0.remote == nil && $0.cloudVM == nil }.flatMap { workspace in
            [workspace.workingDirectory] + workspace.layout.tabs.compactMap(\.workingDirectory)
        }
        guard !folders.isEmpty else { return }
        var seen = Set<String>()
        let saved = classicFolderDefaults?.stringArray(forKey: Self.classicFoldersKey) ?? []
        let combined = (saved + folders).filter { seen.insert($0).inserted }
        classicFolderDefaults?.set(combined, forKey: Self.classicFoldersKey)
        addProjectFolders(combined)
    }

    private func addProjectFolders(_ folders: [String]) {
        var seen = Set(projectFolders)
        projectFolders += folders.compactMap { path in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    /// Follows `browser.import.enabled` from `settings` (`AppServices.settings`).
    func followImportSetting(_ settings: SettingsController) {
        importSettingFollow?.cancel()
        importSettingFollow = BrowserImportGate(host: services).follow(settings)
        cookieBannerFollow?.cancel()
        cookieBannerFollow = browserImportOffer.followBannerSetting(settings)
    }

    /// `browser.import.enabled` turned off: the browser tab's offer goes and an Import from Browser
    /// window still open closes.
    func importTurnedOff() {
        browserImportOffer.importTurnedOff()
        guard let controller, controller.model.step == .importData else { return }
        controller.close()
    }

    /// Opens the tool window for `step` (or brings the open one forward).
    /// `importKinds` checks only those kinds on the import step and
    /// `importTarget` names the cmux browser profile they go into (the
    /// browser-data offer: into the tab's profile); without kinds the step
    /// makes one profile per source.
    func show(step: OnboardingModel.Step, importKinds: Set<ImportDataKind>? = nil, importTarget: String? = nil) {
        // `browser.import.enabled` off: the import window does not open, whoever asks.
        if step == .importData, !services.browserImportEnabled { return }
        presenter.show(step: step) { model, reused in
            if let importKinds {
                model.importer.preset(kinds: importKinds, into: importTarget)
            } else if reused {
                model.importer.resetTarget()
            }
        }
    }

    /// The guided Computer Use window (`palette.computerUse.setup` and the two Grant actions, which
    /// Settings' Grant Access runs too): every entry opens it, as the earlier app did, never System
    /// Settings by itself. `pane`: a Grant action's grant, whose Allow starts in the window once the
    /// grants are read (System Settings opens with the drag panel docked to it), only on the
    /// person's own run. `byPerson` false (an agent's `cmux action run`): the window comes forward
    /// without the keys, bounces the Dock icon while another app is active, and starts nothing:
    /// Computer Use is never turned on, and System Settings never opens, without the person's Allow.
    /// `inFront`: the run may change the view (the person's run, or one that asked for focus);
    /// otherwise the window opens behind with a Dock bounce. `byPerson`: the person's own gesture
    /// in this app (``ActionInvocation/isPersonsOwnRun``), never an agent's, a page's or a
    /// `focus` request: only that starts the grant's Allow, which can turn Computer Use on.
    func showComputerUse(allowing pane: ComputerUsePermissionPane? = nil, inFront: Bool, byPerson: Bool) {
        computerUseSetup.recheck()
        presenter.show(step: .computerUse, quietly: !inFront) { model, _ in
            if let pane, byPerson { model.computerUse.allowOnceKnown(pane) }
        }
    }

    /// A Sign In's login in a local terminal tab (false: none opened). A top page covers it, so it shows once the page is left.
    private func openSignIn(_ line: String) async -> Bool {
        if let window = services.windows.active, let page = window.shownTopPage, window.leaveTopPage() { pageLeftForSignIn = pageLeftForSignIn ?? page }
        return await services.openLocalProviderLogin(line)
    }

    /// Home's Set Up cmux card (``FirstRunSetup``): what a first run offers, in place of the first-run windows.
    private(set) lazy var setup = FirstRunSetup(skipsOnboarding: services.environment.launchSteps == .none)

    /// Meet Chief (``ChiefOnboarding``): a fresh install's first look at Chief, in its chat (no window: no `--onboarding` needed).
    private(set) lazy var chief = ChiefOnboarding(defaults: .standard, settings: HomeChiefOnboardingSettings { [weak services] in services?.settings },
                                                  skipsOnboarding: services.environment.launchSteps == .none)

    /// The launch's steps (``AppEnvironment/launchSteps``): with onboarding on, a first run starts Home's Set Up cmux card
    /// (the Agents window and the CLI toast count as shown), else the first-run windows
    /// (``OnboardingWindowPresenter/showFirstRunSteps``), after which this Mac's first launch is finished
    /// (``OnboardingWindowPresenter/historyShownKey``).
    func showFirstRunSteps(isFirstRun: Bool) async {
        guard await presenter.showLaunchSteps(services.environment.launchSteps, isFirstRun: isFirstRun) else { return }
        let route = setup.route(isFirstRun: isFirstRun, replacedKeys: [CLIInstallHandlers.offeredAtLaunchKey], screenReader: NSWorkspace.shared.isVoiceOverEnabled)
        if route == .startCard { DebugTimings.markLaunch("first_run.setup_card_shown") }
        guard route == .windows else { return }
        await presenter.showFirstRunSteps(isFirstRun: isFirstRun, source: signInHarnesses) {
            UserDefaults.standard.set(true, forKey: OnboardingWindowPresenter.historyShownKey)
        }
    }

    /// A new person's first launch opens a new agent chat, composer ready, in a workspace of its own (cmux#48416): after
    /// the launch's tool window closes (Make cmux Yours), none over a top page or for terminal-first.
    @discardableResult
    func openFirstChat(isFirstRun: Bool, defaults: UserDefaults = .standard) async -> String? {
        await presenter.untilClosed()
        let terminalFirst = (firstRunChoices.pickedWorkStyle ?? firstRunChoices.currentChoices().workStyle) == .terminal
        guard services.agentTabs.canHost(on: services.daemon), services.windows.active?.shownTopPage == nil,
              OnboardingWindowPresenter.claimFirstChat(isFirstRun: isFirstRun, steps: services.environment.launchSteps,
                                                       terminalFirst: terminalFirst, defaults: defaults) else { return nil }
        var spawn = WorkspaceSpawn(cwd: nil)
        spawn.firstChat = AgentPaneSeed()
        do { return try await services.windows.createWorkspace(spawn, into: services.windows.active?.state.id) } catch {
            services.daemon.logger.error("first-run agent chat failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension SavingImportDestination {
    /// Into this app: each batch's pages join its browser profile's omnibar history.
    @MainActor static func app(_ services: AppServices, bookmarks: (any ImportedBookmarkSink)? = nil) -> SavingImportDestination {
        SavingImportDestination(sync: services.onboarding.historySync, bookmarks: bookmarks)
    }

    /// Imported pages join (or leave) their browser profile's omnibar history (bookmarks reach it as bookmark rows).
    static func omnibar(_ cache: TabContentCache) -> ImportHistorySync.Deliver {
        { id, pages, gone in
            let entries = pages.map { BrowserHistoryEntry(url: $0.url, title: $0.title, visitCount: $0.visitCount, lastVisit: $0.lastVisit) }
            await MainActor.run { cache.history(for: BrowserProfileRecord.engineProfile(for: id) ?? .default).apply(merging: entries, forgetting: gone) }
        }
    }
}

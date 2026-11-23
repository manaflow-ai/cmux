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
                                                              openTerminal: { [weak self] line in await self?.openSignIn(line) ?? false })
    private(set) lazy var agentTools = AgentToolsStepModel.cliSource(cli: { [bundled = services.bundledCLI] in await bundled.resolve() }, settings: { [weak services] in services?.settings })
    /// Make cmux Yours' choices over the settings owner; density goes through its action, which also applies the tokens.
    private(set) lazy var firstRunChoices = FirstRunChoicesSettingsSource(settings: { [weak services] in services?.settings }, setDensity: { [weak services] preset in
        _ = services?.registry.perform("appearance.density.set", invocation: ActionInvocation(arguments: ["density": .string(preset)], origin: .user))
    })
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
            // Classic's saved folders, read by the daemon (`classic_import.plan`) once it is up.
            let classic = await classicProjectFolders()
            var seen = Set<String>()
            projectFolders = (agent + classic).compactMap { path in
                let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
                return seen.insert(normalized).inserted ? normalized : nil
            }
        }
        presenter.makeModel = { [weak self] step in
            self.map { OnboardingModel(services: AppOnboardingServices(owner: $0), step: step, agentTools: $0.agentTools, choices: $0.firstRunChoices) }
        }
        presenter.onWindowClose = { [weak self] in
            guard let self, let page = pageLeftForSignIn else { return }
            pageLeftForSignIn = nil
            _ = TopPages.show(page, services: services)
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
    /// the launch's tool windows close (Make cmux Yours, the cmux Tools answer), none over a top page or for terminal-first.
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

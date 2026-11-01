import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextImportCards
import CmuxNextOnboarding
import CmuxNextSettings
import os

/// Owns the tool window (Import from Browser, Computer Use setup), the
/// browser-data import offer, the default-app registry and the imported
/// data, and feeds imported history to the omnibar at launch. Nothing opens
/// at launch (Lawrence 2026-10-09: a launch goes straight to the main
/// window); the one-time classic migration only adds classic's workspaces
/// to the restored windows (Lawrence 2026-10-19, classic-migration-DESIGN.md).
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

    /// Where `workspace.importClassic` reads classic's saved session; nil
    /// reads the one classic saved last (tests point it at a fixture).
    var classicSessions: ClassicSessionImporter?
    /// How `workspace.importClassic` reaches a classic SSH workspace's host:
    /// the daemon for that destination. Nil connects through `SSHService`
    /// (tests stand in a daemon).
    var classicSSH: (@MainActor (String) throws -> DaemonService)?
    /// What acpmux would do with a classic agent session (`_acpmux/chat_open`):
    /// only `adopt` opens a chat. Nil asks this Mac's acpmux (tests answer).
    var classicChatPlan: (@MainActor (AgentPaneAdopt, String?) async throws -> AcpmuxChatOpenPlan?)?
    /// The toast `workspace.importClassic` or the launch migration showed last.
    var classicImportNotice: String?
    /// The classic migration's folder (ledger, backups); nil uses
    /// `Application Support/cmux-next/<bundle id>/classic-migration` (tests use a scratch folder).
    var classicMigrationDirectory: URL?
    /// The Application Support folder holding classic's `cmux` folder; nil is this Mac's.
    var classicMigrationSupport: URL?
    /// Whether launch runs the classic migration; nil decides by build (shipping builds only).
    var classicMigrationAtLaunch: Bool?
    /// Whether a classic cmux app is running; nil reads it from how recently classic saved.
    var classicRunning: (@MainActor () -> Bool)?
    /// Classic's state folder, where its launch sentinel says it runs; nil is this Mac's
    /// (`~/.local/state/cmux`); tests use a scratch folder.
    var classicStateRoot: URL?
    /// Answers the migration preview; nil presents the native cmux dialog.
    /// Tests inject an answer without creating UI.
    var classicMigrationConfirmation: (@MainActor (ClassicImportPlan) async -> Bool)?
    /// The migration run in flight or last finished: a new run waits for it.
    var classicMigrationRun: Task<ClassicMigrationOutcome, any Error>?

    /// Keep in Sync's watches; `start` also seeds each profile's omnibar with its imported pages.
    private(set) lazy var historySync = BrowserFolderAccess().historySync(store: importStore, deliver: SavingImportDestination.omnibar(services.cache))

    /// Computer Use Setup: the helper's grants for the palette action, Settings and the tool window.
    private(set) lazy var computerUseSetup = ComputerUseSetup.app(services: services)

    init(services: AppServices) {
        self.services = services
        presenter = OnboardingWindowPresenter(activeLook: services.activeLook)
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
                // Folders on this Mac: an SSH or Cloud VM workspace's are another machine's.
                let classicFolders = classic.filter { $0.remote == nil && $0.cloudVM == nil }.flatMap { workspace in
                    [workspace.workingDirectory] + workspace.layout.tabs.compactMap(\.workingDirectory)
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

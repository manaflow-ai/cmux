import struct CmuxSafeConcurrency.OwnerReference
import AppKit
import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextApps
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextChiefViews
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemonRecovery
import CmuxNextDesign
import CmuxNextFeed
import CmuxNextFloating
import CmuxNextHibernation
import CmuxNextHistory
import CmuxNextHome
import CmuxNextIcons
import CmuxNextLayout
import CmuxNextOnboarding
import CmuxNextPages
import CmuxNextPalette
import CmuxNextServer
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextTasks
import CmuxNextWorkspaceNaming
import Foundation

/// Every tunable the app declares, by module. One list, so the window, the
/// store's validation and the exports agree.
enum TunableCatalog {
    static var all: [TunableDescriptor] {
        // The Chief view gallery's toggle (its own line, so the busy list below merges cleanly).
        ChiefViewsPage.tunables +
        DesignTunables.all + [IconFamily.tunable.descriptor] + LayoutTunables.all + TabTunables.all + SidebarTunables.all + DragTunables.all
            + [AgentPaneTunables.inspector.descriptor]
            + AgentActivityTunables.all + TasksTunables.all + AppsTunables.all + PageTunables.all + AgentPaneTunables.all + PaletteTunables.all + ServerTunables.all + DaemonTunables.all + FeedTunables.all
            + SettingsPresentation.tunables + NewTabTunables.all + WhatsNewTunables.all + WorkspaceAutoNameTunables.all + QuickComposerTunables.all + ChiefPetTunables.all + HomeTunables.all + HomeTunables.headerPanels + [SidebarToggleIcon.tunable.descriptor] + BrowserImportTunables.all + NavigationTunables.all + BrowserResizeTunables.all + BrowserPageTunables.all + AccountTunables.all
            + TitlebarHistoryTunables.all + HibernationTunables.all + MemoryDiscardToggles.all + CloudTunables.all
            + HangFileTunables.all + HostPressureTunables.all
            + BrowserHostTunables.all
    }
}

/// Owns Debug Settings (DEV and NIGHTLY builds, `DevTools`): activates the
/// tunable store at launch with this build's override file (also in a bench
/// build that a bench script gives one, ``loadsTunables``), and opens it
/// (palette "Open Debug Settings", `action.run openDebugSettings`,
/// `debug.tunables`) as an internal page tab, or as its own window like
/// Settings (`settings.presentation`). In Release and RC nothing here runs:
/// the store stays inert, so every tunable keeps its code default and no
/// file is read.
@MainActor
final class DebugSettingsService: InternalPageProvider {
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    private var controller: DebugSettingsWindowController?
    private var sharedModel: DebugSettingsModel?
    /// The React page of the window and of each tab (by key), closed through the host that opened
    /// it (`services.webUI.close`) with its window or tab. Only that close ends the page's
    /// subscriptions: the router's event handler holds the ``DebugSettingsPageProvider``, so a page
    /// left open keeps following the hang files and rebuilding its state for a page nobody shows.
    private var windowPage: PageWebView?
    private var tabPages: [String: PageWebView] = [:]
    /// Where overrides persist (nil before launch or without dev tools).
    private(set) var fileURL: URL?

    /// Scratch override for tests, like `CMUX_NEXT_CONFIG_FILE`.
    nonisolated static let fileOverrideKey = "CMUX_NEXT_DEBUG_TUNABLES_FILE"

    init(services: AppServices) {
        servicesReference = OwnerReference(services: services)
    }

    var isAvailable: Bool { DevTools.isEnabled }
    var model: DebugSettingsModel? { sharedModel }
    var window: NSWindow? {
        if let window = controller?.window { return window }
        guard let services else { return nil }
        return services.pages.window(showing: .debugSettings, windows: services.windows.controllers)?.window
    }

    /// Registers the catalog and activates the store (dev tools, or a bench run's override file).
    func start() {
        guard let services, let url = Self.launchFile(launch: services.environment.launch, environment: ProcessInfo.processInfo.environment) else { return }
        let store = TunableStore.shared
        store.register(TunableCatalog.all)
        BrowserResizeTunables.registerRenames(store)
        fileURL = url
        store.activate(file: TunableStore.FileSource(url: url, landingOn: services.mainWork))
        // The Sentry scope names the arm features.list reports, the file's toggles and later changes included.
        let features = FeatureFlagsPage.report(services.features, tunables: store, daemon: services.environment.daemonFeatureHello)
        services.lifetimeFollowers.append(services.crashReporting.reporter.followFeatures(on: services.mainWork) { CrashFeatureScope(features.fieldState) })
        // CmuxNextCloud does not see tunables; Release keeps CloudAuth's default (automatic).
        services.cloud.auth.signInWindow = { .init(rawValue: AccountTunables.signInWindow.value.rawValue) ?? .automatic }
        // The store loads the file off the main actor, after the first icons draw: the family is read here.
        IconPack.useOverlay(Self.launchIconFamily(url).overlay)
    }

    /// The override file launch activates the tunable store with (``loadsTunables``), or nil where it stays inert.
    /// `main` reads the tunables features replace from it before the launch's features resolve.
    nonisolated static func launchFile(launch: LaunchIdentity, environment: [String: String]) -> URL? {
        guard loadsTunables(devTools: DevTools.isEnabled, benchBuild: isBenchBuild,
                            bundleID: launch.bundleID, environment: environment) else { return nil }
        return fileURL(environment: environment, tag: launch.tag, bundleID: launch.bundleID, build: launch.build)
    }

    /// Whether launch activates the tunable store: with dev tools, or in a bench build
    /// (`reload.sh --config bench`) of a development bundle whose bench script names its
    /// override file (`CMUX_NEXT_DEBUG_TUNABLES_FILE`, as chromium-host-bench.py does). A bench
    /// run's tunables then apply and `debug.tunables` can change them, while the Debug
    /// Settings window and the `isDebugOnly` actions stay off (``DevTools``).
    nonisolated static func loadsTunables(devTools: Bool, benchBuild: Bool, bundleID: String?,
                                          environment: [String: String]) -> Bool {
        if devTools { return true }
        guard benchBuild, let bundle = bundleID, bundle.contains(".debug") || bundle.hasSuffix(".dev") else { return false }
        return !(environment[fileOverrideKey]?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty
    }

    /// Whether this compile is a bench build (`-DCMUX_BENCH_HOOKS`).
    nonisolated static var isBenchBuild: Bool {
        #if CMUX_BENCH_HOOKS
        true
        #else
        false
        #endif
    }

    /// Debug Settings `icons.family` as the override file holds it at launch (`pack` without one).
    nonisolated static func launchIconFamily(_ url: URL?) -> IconFamily {
        // concurrency-allow: one small Debug Settings file, read once at launch before the first icon draws
        guard let url, let data = try? Data(contentsOf: url) else { return .pack }
        return (TunableFile.decode(data)[IconFamily.tunable.key] as? String).flatMap(IconFamily.init(rawValue:)) ?? .pack
    }

    /// `~/Library/Application Support/cmux/<tag or channel>/debug-tunables.json`
    /// for a build that keeps its app names (``BuildIdentity/keepsAppNames``),
    /// `cmux/builds/<key>/debug-tunables.json` for every other build, so no
    /// build reads another's tunables (per-build isolation S5, cx-is1kf.6);
    /// or the `CMUX_NEXT_DEBUG_TUNABLES_FILE` override.
    nonisolated static func fileURL(environment: [String: String], tag: String?, bundleID: String?,
                                    build: BuildIdentity? = nil,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = environment[fileOverrideKey]?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let cmux = home.appending(path: "Library/Application Support/cmux")
        if let build, !build.keepsAppNames, let state = build.daemonStateDirectory(appSupport: cmux) {
            return state.deletingLastPathComponent().appending(path: "debug-tunables.json")
        }
        let folder = tag ?? (bundleID.map { $0.hasPrefix(DevTools.nightlyBundleID) ? "nightly" : "dev" } ?? "dev")
        return cmux.appending(path: folder)
            .appending(path: "debug-tunables.json")
    }

    /// Opens (or brings back) the window. Throws when this build has no
    /// developer tools.
    func show(query: String? = nil, selection: DebugSettingsSelection? = nil, focus: Bool = true) throws {
        guard isAvailable else { throw ActionFailure(message: RefusalStrings.debugSettingsUnavailable) }
        guard let services else { throw ActionFailure.appClosing }
        let model = sharedModel ?? DebugSettingsModel(store: TunableStore.shared, descriptors: TunableCatalog.all)
        sharedModel = model
        if SettingsPresentation.tunable.value == .pane, let window = services.windows.active {
            if let query { model.query = query }
            if let selection { model.selection = selection }
            DebugSettingsModel.followTheme(window.themeScope)
            if services.pages.show(.debugSettings, in: window, focus: focus) != nil { return }
        }
        if controller == nil {
            let page = webPage(model: model, services: services)
            windowPage = page
            let controller = DebugSettingsWindowController(model: model, content: page,
                                                           onFind: page.map { page in { _ = page.send(command: "focusSearch") } })
            controller.onClose = { [weak self] in
                guard let self else { return }
                if let page = windowPage { self.services?.webUI.close(page) }
                windowPage = nil
                self.controller = nil
                dropModelWhenUnused()
            }
            self.controller = controller
        }
        controller?.setThemeScope(services.windows.active?.themeScope ?? .app)
        controller?.present(query: query, selection: selection)
    }

    /// Closes the window and every Debug Settings tab.
    func close() {
        controller?.window?.performClose(nil)
        guard let services else { return }
        for key in services.pages.keys(of: .debugSettings) {
            guard let pane = services.paneController(showingTab: key), let id = services.pages.stripID(showing: key, in: pane) else { continue }
            pane.close([id])
        }
    }

    private func dropModelWhenUnused() {
        guard controller == nil, services?.pageIsOpen(.debugSettings) != true else { return }
        sharedModel = nil
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .debugSettings }
    var title: String { DebugSettingsModel.paneTitle }
    var symbol: String { "slider.horizontal.3" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let model = sharedModel ?? DebugSettingsModel(store: TunableStore.shared, descriptors: TunableCatalog.all)
        sharedModel = model
        if let services, let page = webPage(model: model, services: services) {
            // Called once per tab; a replaced page is no tab's view.
            if let replaced = tabPages.updateValue(page, forKey: key) { services.webUI.close(replaced) }
            DebugSettingsModel.followTheme(window?.themeScope ?? .app)
            return page
        }
        return VisibilityGatedHostingView(owner: "DebugSettingsPage", hosting: model.makePaneView(scope: window?.themeScope ?? .app))
    }

    /// The React page over `model` when Debug Settings `debugSettings.surface` is `web` (the
    /// default), else nil (the SwiftUI view). Its own window has a standard title bar
    /// (`DebugSettingsWindowController`), so the page needs no title bar inset.
    private func webPage(model: DebugSettingsModel, services: AppServices) -> PageWebView? {
        guard PageTunables.debugSettings.value == .web else { return nil }
        let provider = DebugSettingsPageProvider(model: model, hangs: services.quit.watchdog?.episodes, on: services.mainWork)
        let native = AppPageNativeProvider(services: services, page: .debugSettings)
        let routes = [PageRoute(prefix: "cmux.debug.tunables.", provider: provider), PageRoute(prefix: "cmux.app.", provider: native)]
        guard let page = services.webUI.open(PageOpenRequest(descriptor: .debugSettings, routes: routes)) else { return nil }
        native.anchor = { [weak page] in page }
        return page
    }

    func tabClosed(_ key: String) {
        if let page = tabPages.removeValue(forKey: key) { services?.webUI.close(page) }
        dropModelWhenUnused()
    }

    // MARK: Discard (`memoryDiscardInternalPages`)

    /// Ten minutes hidden: a tunable is written as it changes, and the search and selection live in
    /// the shared model, which stays while the tab does, so the next page opens where it was.
    func discardPolicy(for key: String) -> ContentDiscardPolicy { .standard }

    /// The tab's page went (the tab store closed it); the model stays with the tab.
    func viewDiscarded(_ key: String) {
        if let page = tabPages.removeValue(forKey: key) { services?.webUI.close(page) }
    }
}

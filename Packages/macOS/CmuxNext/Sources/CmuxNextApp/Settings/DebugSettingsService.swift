import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentPane
import CmuxNextApps
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextFeed
import CmuxNextHome
import CmuxNextLayout
import CmuxNextPages
import CmuxNextPalette
import CmuxNextServer
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextTasks
import Foundation

/// Every tunable the app declares, by module. One list, so the window, the
/// store's validation and the exports agree.
enum TunableCatalog {
    static var all: [TunableDescriptor] {
        DesignTunables.all + LayoutTunables.all + TabTunables.all + SidebarTunables.all + DragTunables.all
            + AgentActivityTunables.all + TasksTunables.all + AppsTunables.all + PageTunables.all + AgentPaneTunables.all + PaletteTunables.all + ServerTunables.all + FeedTunables.all
            + SettingsPresentation.tunables + NewTabTunables.all + HomeTunables.all + [SidebarToggleIcon.tunable.descriptor]
    }
}

/// Owns Debug Settings (DEV and NIGHTLY builds, `DevTools`): activates the
/// tunable store at launch with this build's override file, and opens it
/// (palette "Open Debug Settings", `action.run openDebugSettings`,
/// `debug.tunables`) as an internal page tab, or as its own window like
/// Settings (`settings.presentation`). In Release and RC nothing here runs:
/// the store stays inert, so every tunable keeps its code default and no
/// file is read.
@MainActor
final class DebugSettingsService: InternalPageProvider {
    unowned let services: AppServices
    private var controller: DebugSettingsWindowController?
    private var sharedModel: DebugSettingsModel?
    /// Where overrides persist (nil before launch or without dev tools).
    private(set) var fileURL: URL?

    /// Scratch override for tests, like `CMUX_NEXT_CONFIG_FILE`.
    nonisolated static let fileOverrideKey = "CMUX_NEXT_DEBUG_TUNABLES_FILE"

    init(services: AppServices) {
        self.services = services
    }

    var isAvailable: Bool { DevTools.isEnabled }
    var model: DebugSettingsModel? { sharedModel }
    var window: NSWindow? {
        controller?.window ?? services.pages.window(showing: .debugSettings, windows: services.windows.controllers)?.window
    }

    /// Registers the catalog and activates the store (dev tools only).
    func start() {
        guard isAvailable else { return }
        let store = TunableStore.shared
        store.register(TunableCatalog.all)
        let url = Self.fileURL(environment: ProcessInfo.processInfo.environment, tag: services.environment.launch.tag,
                               bundleID: services.environment.launch.bundleID)
        fileURL = url
        store.activate(file: url)
    }

    /// `~/Library/Application Support/cmux/<tag or channel>/debug-tunables.json`,
    /// or the `CMUX_NEXT_DEBUG_TUNABLES_FILE` override.
    nonisolated static func fileURL(environment: [String: String], tag: String?, bundleID: String?,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let path = environment[fileOverrideKey]?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let folder = tag ?? (bundleID.map { $0.hasPrefix(DevTools.nightlyBundleID) ? "nightly" : "dev" } ?? "dev")
        return home.appending(path: "Library/Application Support/cmux").appending(path: folder)
            .appending(path: "debug-tunables.json")
    }

    /// Opens (or brings back) the window. Throws when this build has no
    /// developer tools.
    func show(query: String? = nil, selection: DebugSettingsSelection? = nil, focus: Bool = true) throws {
        guard isAvailable else { throw ActionFailure(message: RefusalStrings.debugSettingsUnavailable) }
        let model = sharedModel ?? DebugSettingsModel(store: TunableStore.shared, descriptors: TunableCatalog.all)
        sharedModel = model
        if SettingsPresentation.tunable.value == .pane, let window = services.windows.active {
            if let query { model.query = query }
            if let selection { model.selection = selection }
            DebugSettingsModel.followTheme(window.themeScope)
            if services.pages.show(.debugSettings, in: window, focus: focus) != nil { return }
        }
        if controller == nil {
            let controller = DebugSettingsWindowController(model: model)
            controller.onClose = { [weak self] in
                self?.controller = nil
                self?.dropModelWhenUnused()
            }
            self.controller = controller
        }
        controller?.setThemeScope(services.windows.active?.themeScope ?? .app)
        controller?.present(query: query, selection: selection)
    }

    /// Closes the window and every Debug Settings tab.
    func close() {
        controller?.window?.performClose(nil)
        for key in services.pages.keys(of: .debugSettings) {
            guard let pane = services.paneController(showingTab: key), let id = services.pages.stripID(showing: key, in: pane) else { continue }
            pane.close([id])
        }
    }

    private func dropModelWhenUnused() {
        guard controller == nil, services.pages.keys(of: .debugSettings).isEmpty else { return }
        sharedModel = nil
    }

    // MARK: InternalPageProvider

    var page: InternalPageID { .debugSettings }
    var title: String { DebugSettingsModel.paneTitle }
    var symbol: String { "slider.horizontal.3" }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        let model = sharedModel ?? DebugSettingsModel(store: TunableStore.shared, descriptors: TunableCatalog.all)
        sharedModel = model
        return model.makePaneView(scope: window?.themeScope ?? .app)
    }

    func tabClosed(_ key: String) {
        dropModelWhenUnused()
    }
}

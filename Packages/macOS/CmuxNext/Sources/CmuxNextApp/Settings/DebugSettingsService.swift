import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextApps
import CmuxNextDesign
import CmuxNextFeed
import CmuxNextLayout
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
            + AgentActivityTunables.all + TasksTunables.all + AppsTunables.all + PaletteTunables.all + ServerTunables.all + FeedTunables.all
            + SettingsWindowLayout.tunables
    }
}

/// Owns Debug Settings (DEV and NIGHTLY builds, `DevTools`): activates the
/// tunable store at launch with this build's override file, and opens the
/// window (palette "Open Debug Settings", `action.run openDebugSettings`,
/// `debug.tunables`). In Release and RC nothing here runs: the store stays
/// inert, so every tunable keeps its code default and no file is read.
@MainActor
final class DebugSettingsService {
    unowned let services: AppServices
    private var controller: DebugSettingsWindowController?
    /// Where overrides persist (nil before launch or without dev tools).
    private(set) var fileURL: URL?

    /// Scratch override for tests, like `CMUX_NEXT_CONFIG_FILE`.
    nonisolated static let fileOverrideKey = "CMUX_NEXT_DEBUG_TUNABLES_FILE"

    init(services: AppServices) {
        self.services = services
    }

    var isAvailable: Bool { DevTools.isEnabled }
    var model: DebugSettingsModel? { controller?.model }
    var window: NSWindow? { controller?.window }

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
    func show(query: String? = nil, selection: DebugSettingsSelection? = nil) throws {
        guard isAvailable else { throw ActionFailure(message: RefusalStrings.debugSettingsUnavailable) }
        if controller == nil {
            let model = DebugSettingsModel(store: TunableStore.shared, descriptors: TunableCatalog.all)
            let controller = DebugSettingsWindowController(model: model)
            controller.onClose = { [weak self] in self?.controller = nil }
            self.controller = controller
        }
        controller?.setThemeScope(services.windows.active?.themeScope ?? .app)
        controller?.present(query: query, selection: selection)
    }

    func close() {
        controller?.window?.performClose(nil)
    }
}

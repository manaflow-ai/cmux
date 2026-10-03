import AppKit
import CmuxNextApps
import Foundation

/// App platform in the App (plans/cmux-next/app-platform.md section 13):
/// the client of the local daemon's app supervisor (`apps-v1`) and the App
/// Store window. The supervisor owns installs, grants, app hosts and
/// storage; the App renders scene streams and sends user events. When the
/// daemon lacks `apps-v1` the store and app sections show "Needs a newer
/// cmux-tui" and every change is refused.
@MainActor
final class AppsService {
    unowned let services: AppServices
    let client: AppsClient
    /// App sidebar sections; they show only for presented apps (`presence`).
    private(set) lazy var sections = AppSectionProvider(client: client) { [unowned self] in presence.isPresented($0) }
    private var store: AppStoreWindowController?

    init(services: AppServices) {
        self.services = services
        client = AppsClient(transport: DaemonAppsTransport(daemon: services.daemon))
    }

    func start() {
        // Root cause of a 7.5 s main-thread stall when the store opened: the
        // bundled samples were scanned on the main actor. Resources now load
        // once off the main actor; the store renders from the client mirror.
        // task-owner: one resource preload at launch
        Task { await AppPlatformResources.preload() }
        client.start()
    }

    /// Opens the App Store window (palette "App Store", `appStore.show`):
    /// on a listing when `appID` is given, else on Installed when asked.
    /// Drawn in the theme of the window it was opened from.
    func showStore(appID: String? = nil, installed: Bool = false) {
        if store == nil {
            let controller = AppStoreWindowController(model: AppStoreModel(client: client))
            controller.onClose = { [weak self] in self?.store = nil }
            store = controller
        }
        store?.setThemeScope(services.windows.active?.themeScope ?? .app)
        store?.present(appID: appID, installed: installed)
    }

    /// Hide or unhide (`app.hide`, `app.unhide`): any origin, agents
    /// included, because hiding grants nothing (V9). Installs never come
    /// through here.
    func setHidden(_ appID: String, _ hidden: Bool, origin: AppOrigin) async throws(AppsClientError) {
        guard client.app(appID)?.installed == true else { throw .unknownApp(appID) }
        try await client.set(appID, .hide(hidden), origin: origin)
    }
}

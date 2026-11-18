import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// New Private Tab (Leo, 2026-11-18: "what if in [a browser] you could simply have an incognito tab?"): a private
/// browser tab in the focused pane of the active window, a normal window included. It uses the incognito
/// session's profile, its record is a placeholder marked private (`private-tabs-v1`), and its URL stays in
/// app memory (`BrowserTabService.open(incognito:)`). In an incognito window it is that window's new tab.
/// A daemon without private tabs, or no pane to open it in, gets a new incognito window instead.
@MainActor
enum PrivateTabs {
    static func open(_ services: AppServices) {
        guard let window = services.windows.active, let controller = window.focusedPane else {
            services.windows.newIncognitoWindow()
            return
        }
        if services.windows.isIncognito(window: window.state.id) {
            _ = controller.newBrowserTab()
            return
        }
        let browserTabs = services.cache.browserTabs, model = controller.pane
        guard controller.daemon.supports(DaemonCapability.privateTabs.rawValue), browserTabs.isAvailable(in: model) else {
            services.windows.newIncognitoWindow()
            return
        }
        let choice: BrowserEngineChoice
        switch browserTabs.resolve(requested: nil) {
        case .refuse(let reason): return services.registry.refuse(BrowserTabService.message(reason))
        case .open(let resolved): choice = resolved
        }
        // The session begins now, so the tab's first page is incognito; the watch ends it after the last private tab.
        _ = services.windows.incognitoProfile()
        let address = services.newTabAddress(for: choice)
        let intent = controller.workspace?.beginFocusIntent()
        services.registry.track(Task {
            defer { services.windows.watchPrivateTabs() }
            do {
                let surface = try await browserTabs.open(choice, in: model, url: address, incognito: true)
                controller.selectWhenReported(surface: surface)
                controller.workspace?.expectFocus(on: surface, target: .addressBar, generation: intent)
                return nil
            } catch {
                controller.daemon.logger.error("new private tab failed: \(String(describing: error), privacy: .public)")
                return "new private tab: \(error)"
            }
        })
    }
}

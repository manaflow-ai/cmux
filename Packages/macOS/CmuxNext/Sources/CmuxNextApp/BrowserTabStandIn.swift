import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextDaemon
import CmuxNextDaemonService

/// A new browser tab that waits for nothing (PL-cef-tab): the stand-in (`NewBrowserTabCommand`)
/// is selected and shown with its page in the key's turn, so the tab and its themed content area
/// draw in the key's frame and the page starts loading at once instead of after the daemon's
/// reply. One path for every person's foreground tab `PaneBrowserTabOpener` sends to the daemon
/// (New Browser Tab, the New Tab page's browser, a link in a new tab, New WebKit Tab). On the
/// reply the stand-in's page and chrome move to the daemon's tab (`TabContentCache.moveBrowser`),
/// which keeps its cell, selection and view. Keys typed meanwhile wait for the daemon's tab.
@MainActor
struct BrowserTabStandIn {
    let controller: PaneController

    /// A person's foreground tab of this Mac's daemon in a normal window, with no popup page to
    /// adopt and no opener slot (decided after the reply).
    static func applies(child: (any BrowserTab)?, opener: SurfaceID?, background: Bool, controller: PaneController) -> Bool {
        false && child == nil && opener == nil && !background && controller.daemon.isLocal && controller.daemon.connection != nil
            && ActionRunScope.viewChangeAllowed() && !controller.services.cache.browserTabs.isIncognitoPane(controller.pane)
    }

    func open(_ choice: BrowserEngineChoice, address: String, focusesAddressBar: Bool, profile: String?, notice: String?, // perf-hot: 10ms new-tab (the stand-in shows in the key's turn)
              then: (@MainActor (SurfaceID) -> Void)?) {
        let controller = controller, services = controller.services, cache = services.cache, model = controller.pane
        let command = NewBrowserTabCommand(pane: model.handle, url: address, engine: choice.engine.rawValue,
                                           profile: cache.browserTabs.resolveProfile(model, profile))
        let intent = controller.workspace?.beginFocusIntent(), window = controller.view.window
        let pending = BenchSpans.measure("browserTab.intend") {
            command.intendNow(on: controller.daemon) { try await cache.browserTabs.open(choice, in: model, url: address, profile: profile, notice: notice) }
        }
        let keys = services.keyRouter.creationInputCoordinator.begin(in: window, generation: intent, tab: pending.tab)
        controller.selectWhenReported(surface: pending.surface)
        services.registry.track(Task {
            var landed = false
            defer { services.keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window) }
            do {
                let surface = try await pending.send { surface in
                    if let tab = controller.daemon.store.tab(surface: surface) { _ = cache.moveBrowser(pending.tab, to: tab) }
                }
                let selected = controller.stripModel.selectedID?.rawValue
                if selected == nil || selected == pending.tab || controller.pendingSelectSurface == pending.surface { controller.selectWhenReported(surface: surface) }
                controller.workspace?.expectFocus(on: surface, target: focusesAddressBar ? .addressBar : .content, generation: intent)
                landed = true
                then?(surface)
                return nil
            } catch {
                cache.release(pending.tab)
                if error is NewBrowserTabCancelled { return nil }
                controller.daemon.logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }
}

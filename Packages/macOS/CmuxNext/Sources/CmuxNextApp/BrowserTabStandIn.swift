import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDaemonService

/// A new browser tab that waits for nothing (PL-cef-tab, perf-lead issue 1): a stand-in tab is in
/// the pane's store, selected and shown with its page in the key's turn, so the tab and its themed
/// content area draw in the key's frame (target: < 10 ms from the key, both engines), and the page
/// starts loading at once instead of after the daemon's reply.
///
/// One path for every person's new browser tab that `PaneBrowserTabOpener` sends to the daemon in
/// the foreground (New Browser Tab, the New Tab page's browser choice, a link opened in a new
/// tab, New WebKit Tab): the store's create intent shows the stand-in under a request id (the
/// intent's transaction); `new-frontend-browser-tab` runs behind it. On the reply the stand-in's
/// page moves to the daemon's tab (`TabContentCache.handOverBrowser`, adopted as a popup's page
/// is), and the daemon's tab takes the stand-in's place, cell and selection in one apply
/// (``ProvisionalTab/created(_:surface:in:)``, `NewTabSuccession`). The daemon's `tab-added`
/// that comes before its reply is hidden meanwhile (``ProvisionalTab/matched(_:in:)``). A refusal
/// rejects the intent: the stand-in and its page go. A stand-in the person closed first is a
/// cancelled creation (`CancelledCreation`): the daemon's tab closes as soon as it is named.
/// Keys typed meanwhile wait for the daemon's tab (`CreationInputCoordinator`), so none lands in
/// the tab the key came from.
@MainActor
struct BrowserTabStandIn {
    let controller: PaneController

    /// Whether this open takes the stand-in: a foreground tab of this Mac's daemon in a normal
    /// window, run by the person (a script's tab is made in the background, as reported), that
    /// opens no popup and goes where a new tab goes (an opener's slot is decided after the reply).
    static func applies(child: (any BrowserTab)?, opener: SurfaceID?, background: Bool, controller: PaneController) -> Bool {
        child == nil && opener == nil && !background && controller.daemon.isLocal && controller.daemon.connection != nil
            && ActionRunScope.viewChangeAllowed() && !controller.services.cache.browserTabs.isIncognitoPane(controller.pane)
    }

    /// Shows the stand-in now and sends the create behind it. `address` is the page it opens,
    /// `focusesAddressBar` a blank tab's focus (its address bar), `then` the daemon tab's surface.
    func open(_ choice: BrowserEngineChoice, address: String, focusesAddressBar: Bool, profile: String?, notice: String?, // perf-hot: 10ms new-tab (the stand-in shows in the key's turn)
              then: (@MainActor (SurfaceID) -> Void)?) {
        let services = controller.services, daemon = controller.daemon, store = daemon.store, model = controller.pane
        let browserTabs = services.cache.browserTabs, controller = controller
        let provisional = ProvisionalTab()
        let snapshot = provisional.browser(url: address, engine: choice.engine.rawValue,
                                           profile: browserTabs.resolveProfile(model, profile))
        let transaction = ClientTransactionID.generate()
        let intent = controller.workspace?.beginFocusIntent()
        let window = controller.view.window
        let keys = services.keyRouter.creationInputCoordinator.begin(in: window, generation: intent, tab: provisional.id)
        BenchSpans.measure("browserTab.intend") {
            store.intend(.createTab(pane: model.handle, provisional: snapshot), transaction: transaction)
            controller.selectWhenReported(surface: provisional.surface)
        }
        services.registry.track(Task {
            var landed = false
            defer { services.keyRouter.creationInputCoordinator.resolve(keys, landed: landed, in: window) }
            do {
                let surface = try await browserTabs.open(choice, in: model, url: address, profile: profile, notice: notice)
                BenchSpans.mark("daemon.newBrowserTab.returned")
                // The records hold the daemon's tab (hidden while it stands in for this one, or not
                // yet listed) once the store applied what the daemon sent before the reply.
                let sequence = await daemon.connection?.eventSequence()
                await store.applied(through: sequence)
                let cancelled = store.creations.wasCancelled(transaction)
                // In one turn: the daemon's tab takes the stand-in's place, and the page moves to it
                // before any pane shows it (a store change reaches the panes and the cache's gone-tab
                // watch in a later turn). A daemon tab the records do not show yet keeps the
                // stand-in on screen with its page; the daemon's tab then makes its own.
                ProvisionalTab.created(transaction, surface: surface, in: store)
                if !cancelled, store.tab(surface: surface) != nil, let page = services.cache.handOverBrowser(provisional.id) {
                    services.cache.pageRequests.adopt(page, surface: surface)
                }
                if let sequence { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
                // Closed first: its page goes with it (the store closes the daemon's tab).
                guard !cancelled else { services.cache.release(provisional.id); return nil }
                // The swap moved the selection already (NewTabSuccession); a pane still on the stand-in follows it.
                let selected = controller.stripModel.selectedID?.rawValue
                if selected == nil || selected == provisional.id || controller.pendingSelectSurface == provisional.surface {
                    controller.selectWhenReported(surface: surface)
                }
                controller.workspace?.expectFocus(on: surface, target: focusesAddressBar ? .addressBar : .content, generation: intent)
                landed = true
                then?(surface)
                return nil
            } catch {
                store.rejectIntent(transaction)
                services.cache.release(provisional.id)
                daemon.logger.error("new-frontend-browser-tab failed: \(String(describing: error), privacy: .public)")
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }
}

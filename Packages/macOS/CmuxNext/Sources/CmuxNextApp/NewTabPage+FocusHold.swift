import AppKit
import CmuxNextAgentPane

extension NewTabPage {
    /// Cmd-T on a pane that already shows a New Tab page (cx-9fl): the page selects its field when
    /// the focus request reaches it, after keys typed since, and a page still loading drops them.
    /// The page is adopted again with a fresh input token (a fresh New Tab page, as Cmd-T means; a
    /// page still loading reads it from its handshake), and the window's keys wait
    /// (`CreationInputCoordinator`) until the page's field answers `newTab.inputReady` with that
    /// token: an answer from an older Cmd-T does not match. A page that can no longer answer (it
    /// crashed for good or failed to load) ends the hold too, as do a click and a workspace or
    /// window switch.
    static func focusShown(_ view: AgentPaneView, in pane: PaneController) {
        // An earlier Cmd-T on this page still waiting ends first: its token can no longer be answered.
        view.onPageGone?()
        let coordinator = pane.services.keyRouter.creationInputCoordinator
        let window = pane.view.window
        let generation = pane.services.windowController(showing: pane)?.focus.state.generation
        guard let ticket = coordinator.begin(in: window, generation: generation) else { return view.focusLocation() }
        guard var page = view.model.newTab else {
            coordinator.resolve(ticket, landed: false, in: window)
            return view.focusLocation()
        }
        let token = UUID().uuidString
        page.inputToken = token
        let model = view.model
        let previous = model.onNewTabInputReady
        let end: @MainActor () -> Void = { [weak model, weak view, weak window] in
            // One end per hold; the page's own handler stays.
            model?.onNewTabInputReady = previous
            view?.onPageGone = nil
            coordinator.resolve(ticket, landed: false, in: window)
        }
        #if DEBUG
        let deaf = coordinator.takeIgnorePageAnswer()
        #else
        let deaf = false
        #endif
        model.onNewTabInputReady = { answer in
            previous?(answer)
            if answer == token, !deaf { end() }
        }
        view.onPageGone = end
        view.adoptNewTab(page)
    }
}

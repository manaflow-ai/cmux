import AppKit
import CmuxNextAgentPane

extension NewTabPage {
    /// Cmd-T on a pane that already shows a New Tab page (cx-9fl): the page selects its field when
    /// the focus request reaches it, after keys typed since, and a page still loading drops them.
    /// The window's keys wait (`CreationInputCoordinator`) until the page answers
    /// `newTab.inputReady`: right after its focus, or at its mount, whose handshake carries the
    /// token. The hold's other ends (a click, a workspace or window switch) still apply.
    static func focusShown(_ view: AgentPaneView, in pane: PaneController) {
        let coordinator = pane.services.keyRouter.creationInputCoordinator
        let window = pane.view.window
        let generation = pane.services.windowController(showing: pane)?.focus.state.generation
        guard let ticket = coordinator.begin(in: window, generation: generation) else { return view.focusLocation() }
        let model = view.model
        let previous = model.onNewTabInputReady
        model.onNewTabInputReady = { [weak model, weak window] token in
            previous?(token)
            // One answer ends this hold; the page's own handler stays.
            model?.onNewTabInputReady = previous
            coordinator.resolve(ticket, landed: false, in: window)
        }
        view.focusLocation(token: UUID().uuidString)
    }
}

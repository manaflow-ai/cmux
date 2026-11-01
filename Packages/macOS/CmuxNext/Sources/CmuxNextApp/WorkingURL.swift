import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

extension PaneController {
    /// New Browser Tab without a URL opens what the selected tab works on
    /// (#16620): an agent's newest dev server or pull request (the page lists
    /// no other URLs), a terminal's
    /// dev server, else a blank tab. `opener` opens it (the strip pane, for
    /// a browser asked for from the docked agent chat); nil is this pane.
    func newBrowserTabFromSelectedTab(engine: String?, in opener: PaneController? = nil, background: Bool = false,
                                      placementOwner: Bool = false,
                                      then: (@MainActor (SurfaceID) -> Void)? = nil) {
        let opener = opener ?? self
        switch currentContent {
        case .agent(let view):
            services.registry.track(Task { [weak opener] in
                let url = await view.workingContext()?.urls.first
                opener?.newBrowserTab(url: url, engine: engine, background: background, placementOwner: placementOwner, then: then)
                return nil
            })
        case .terminal(let entry):
            opener.newBrowserTab(url: WorkingURL.devServer(in: entry.session.surfaceView.viewportText()), engine: engine,
                                 background: background, placementOwner: placementOwner, then: then)
        case .browser, .page, .placeholder, .notice, .conversation, nil:
            opener.newBrowserTab(url: nil, engine: engine, background: background, placementOwner: placementOwner, then: then)
        }
    }

    /// The selected agent tab's page, whose chat a new terminal asks for its
    /// cwd; nil when another kind is selected.
    var selectedAgentView: AgentPaneView? {
        if case .agent(let view) = currentContent { return view }
        return nil
    }
}

import CmuxNextActions
import CmuxNextAgentPane
import Foundation

/// An agent tab's content in `pane`, with its changed files opening beside
/// it: in a new tab of this pane (the file preview is a browser page on a
/// `file://` URL until the preview surface lands), or in the editor app. Both
/// go through the `file.open` action, the path the palette and `cmux file
/// open` take. A turn's local web page opens in a new browser tab of this
/// pane through `openBrowser`. Its own type, not a PaneController
/// extension: PaneController stays under the god-type budget.
@MainActor
struct AgentTabContent {
    let pane: PaneController

    func content(_ key: String) -> TabContent? {
        let services = pane.services
        guard let view = services.agentTabs.view(for: key) else {
            return services.agentTabs.notice(for: key).map(TabContent.notice)
        }
        // Set on each show, so a tab moved to another pane opens files there.
        view.model.onOpenFile = { [weak pane] url, target in
            guard let pane else { return false }
            return pane.services.registry.openAgentFile(path: url.path, target: target, pane: pane.paneKey)
        }
        view.model.onOpenPreview = { [weak pane] url in
            guard let pane else { return false }
            return pane.services.registry.openAgentPreview(url, pane: pane.paneKey)
        }
        return .agent(view)
    }
}
